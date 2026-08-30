# xterm3 — Render pipeline planı

**Tarih:** 2026-08-05 · **Taban:** `master` @ `ccb2ce4`
**Kaynak:** `chatgpt_xterm3_conversation.md` incelemesi + kod doğrulaması

Bu plan, ChatGPT konuşmasındaki önerilerin kodla doğrulanmış hâlidir. Konuşmadaki
"renderer'ı baştan yaz / `drawAtlas`'a geç" önerisi **kabul edilmedi** (gerekçe aşağıda).
Geriye kalan tek gerçek eksik **damage tracking**; plan onu hedefliyor.

---

## Önce: konuşmadaki hangi iddia neden elendi

| İddia | Durum |
|---|---|
| `Cell` nesneleri kullanılıyor, `TypedData`'ya geç | **Yanlış.** `BufferLine` zaten `Uint32List`, hücre başına 4 word (`lib/src/core/buffer/line.dart:11-21`). |
| Font/glyph atlas yok | **Yanlış.** `procedural_glyph_cache.dart` var; `ui.Picture` rasterize edip `(codePoint, cellSize, color)` ile cache'liyor. |
| `drawParagraph` "text çiziyor", Ghostty "texture çiziyor" | **Teknik olarak yanlış.** Skia/Impeller kendi GPU glyph atlas'ını tutuyor. `drawParagraph`'in pahalı kısmı shaping + layout ve o zaten `ParagraphCache` ile cache'li. Cache hit'te kalan iş Ghostty ile aynı: atlas'tan quad. `drawAtlas` o katmanı kaldırmıyor, sadece atlas yönetimini Skia'dan alıp bize veriyor — color emoji, subpixel AA, devicePixelRatio invalidation elle çözülmek zorunda kalıyor. |
| SoA (`FG[] BG[] ATTR[] CHAR[]`) daha hızlı | **Kazandırmaz.** 4 word = 16 byte, cache line 64 byte → AoS'ta bir cache line 4 hücre taşıyor. SoA'da background pass satır başına 4 ayrı stream açıyor, prefetcher daha kötü davranıyor. Dart'ta bounds check gürültüsünün altında kalır. |
| Darboğaz render pipeline | **Ölçülmemiş.** Elimizdeki tek profile-mode gözlemi render'ı frame bütçesinin ~%15'inde gösteriyor. Konuşmada hiç ölçüm yok, mimari şekilden çıkarım yapılmış. |
| **Damage tracking yok** | **Doğru — tek gerçek eksik.** `_paint()` her frame `effectFirstLine..effectLastLine` arası tüm görünür satırları dolaşıyor (`lib/src/ui/render.dart:788-794`). Cursor blink tüm viewport'u yeniden çiziyor. |

Ufak hatalar: WezTerm OpenGL değil wgpu kullanıyor. `linuxmint/warpinator_flutter` diye
bir Dart terminal örneği yok (link uydurma). Puan tabloları (9/10, "Ghostty'nin %80-90'ı")
benchmark'a dayanmıyor.

---

## Faz 0 — Ölçüm altyapısı — **TAMAMLANDI (2026-08-05)**

Plan `example/` altına sıfırdan benchmark sahnesi öngörüyordu; `example/lib/benchmark.dart`
zaten vardı (60 warmup + 400 ölçüm frame, sabit 1000x600 viewport, deterministik byte
stream, UI/raster ayrı). Yapılan iş harness yazmak değil, eksikleri kapatmak oldu:

- `lib/src/ui/render_stats.dart` — `TerminalRenderStats`: `paints`, `paintedLines`,
  paragraph/glyph cache hit-miss, türetilmiş oranlar, `reset()`. `lib/ui.dart`'tan export.
- `paragraph_cache.dart` / `procedural_glyph_cache.dart` — lookup'lar hit/miss sayıyor.
- `render.dart` — `paint()` sayacı + `Timeline.timeSync('RenderTerminal.paint')`
  (`kReleaseMode` guard'lı, release'de bypass).
- `benchmark.dart` — `setup:` parametresi, ikinci rapor tablosu ve yeni **`static`** workload.

Plandaki **idle** senaryosu düşürüldü: `render.dart:328` cursor blink timer'ı 5 saniye sonra
kendini kapatıyor, yani "sonsuz idle repaint" diye bir durum yok, ~6 toggle var — 400 frame
ölçülemez. Yerine `static`: dolu ekran, frame başına **tek hücre** değişiyor. Aynı sinyal
(damage tracking'in hedefi), deterministik ve ölçülebilir.

### Baseline — M1 Pro, macOS 26.5.1, Flutter 3.44.2, profile, 100x37 grid

| workload | UI p50/p99 | raster p50/p99 | satır/paint | cache |
|---|---|---|---|---|
| plain | 1.0 / 1.4 | 1.6 / 2.3 | 38 | para %100, 2110 look/f |
| sgr | 1.7 / 2.0 | 2.0 / 2.3 | 39 | para %100, 2496 look/f |
| **boxdraw** | **2.4 / 2.8** | **3.3 / 3.6** | 38 | glyf **%97.1**, 2220 look/f |
| fullscreen | 1.7 / 2.6 | 1.9 / 2.9 | 37 | glyf %100, 1831 look/f |
| **static** | 1.6 / 1.9 | 2.5 / 2.8 | 37 | para %100, **3514 look/f** |

Bütçe (16.7ms) aşımı: **her workload'da %0.0**. Tam tablo `BENCHMARKS.md`'de.

### Baseline ne söylüyor

1. **Render bütçeye yakın bile değil.** En kötü p99 2.8ms UI / 3.6ms raster. Önceki
   "~%15 frame bütçesi" gözlemi doğrulandı — paint yolu şu an kimseye frame kaybettirmiyor.
2. **Damage tracking'in hedefi gerçek ama küçük.** `static` tek hücre değiştiriyor, yine de
   37 satır geziyor ve 3514 paragraph lookup yapıyor (hepsi hit). UI p50'si 1.6ms —
   3700 hücreyi baştan yazan `fullscreen`'in 1.7ms'inden ayırt edilemiyor. Renderer ikisini
   gerçekten ayırt edemiyor. Faz 3 bu 1.6ms'in çoğunu alır; ama 16.7ms bütçede o headroom
   zaten var.
3. **En pahalı workload `fullscreen` değil `boxdraw`.** Glyph cache hit %97.1; kalan %2.9
   miss vector path'i yeniden kuruyor. Hit oranını yükseltmek Faz 1-3'ten ucuz ve hedefli.
4. **Asıl anormallik flood:** 32.2 MiB / 467ms (70.6 MiB/s), burst boyunca **49.2 fps**.
   Output frame pipeline'ını aç bırakıyor — parse-per-write yolu, paint yolu değil.
   Hiçbir render işi bunu düzeltmez.

**Sonuç:** Faz 4'ün sorusu ("`drawAtlas`'a geçmenin anlamı var mı?") artık Faz 1-3 inşa
edilmeden cevaplanabilir: hayır. Render pipeline planı, ölçümün göstermediği bir darboğazı
hedefliyor. Faz 1-3 yine de yapılıyor — `static`'teki israf gerçek ve satır revizyon sayacı
başka işlere de (scroll, seçim, arama) taban oluyor — ama artık "performans krizi çözümü"
değil, "ölçülmüş küçük bir kazanç" olarak.

---

## Faz 1 — Satır revizyon sayacı — **YAPILDI, BİRLEŞTİRİLMEDİ**

`render-line-picture-cache` branch'inde, Faz 3 ile birlikte duruyor. `master`'a
alınmadı çünkü **tek tüketicisi Faz 3'tü** ve o birleştirilmedi: `master`'da her hücre
yazımında artan ama kimsenin okumadığı bir sayaç olurdu. Ölü kod, ve `setAsciiCells`
gibi sıcak yollarda increment içeriyor. Bir damage-tracking denemesi tekrar gündeme
gelirse branch'ten alınabilir; asıl iş 16 çağrı noktasını bulmaktı ve o bilgi aşağıda
kayıtlı.

Uygulanan hâli plandan iki noktada ayrılıyor:

- **14 leaf mutator yeter, 18 değil.** Bump'lar sadece `_data`'ya veya map'lere doğrudan
  yazan metotlarda, erken return'lerden sonra. `setCodePoint`→`setContent`,
  `setSemanticContent`→`setAttributes`, `clearWideCellAt`/`eraseRange`/
  `_repairWideCellPairing`→`eraseCell` geçişli olarak kapsanıyor.
- **`viewportRevision` `Buffer`'a elle konmadı.** `buffer.dart`'ta satır dizisini
  değiştiren 16 çağrı noktası var (`lines.push` ×7, `lines[i] =` ×6, `swap`, `pop`,
  `maxLength=`); tek tek işaretlemek regresyona açık. Sayaç
  `IndexAwareCircularBuffer`'a kondu — hepsi `_dropChild` / `_adoptChild` /
  `_moveChild` üçlüsünden ve `maxLength` setter'ından geçiyor. Dört bump, tam kapsama.
  `Buffer.viewportRevision` ona delege ediyor.

İki sayacın kapsamı kasıtlı olarak ayrık: `line.revision` hücre içeriğini izler, satırın
başka bir satıra taşınmasına kördür; `viewportRevision` satır→line eşlemesini izler,
hücre içeriğine kördür. Faz 3'ün ikisine birden bakması gerekecek. Alt-screen geçişinde
`Buffer` nesnesi tamamen değiştiği için sayaçlar ancak aynı buffer instance'ı içinde
karşılaştırılabilir — dokümante edildi.

Test: `test/src/core/buffer/line_revision_test.dart`, 27 test — her mutator için bump,
okumaların bump'lamadığı, no-op erken return'lerin bump'lamadığı, ardışık yazmalarda
sayacın hiç tekrar etmediği, `viewportRevision`'ın 5 senaryosu.

**Maliyet ölçüldü:** beş workload'ın dördü baseline'dan hızlı çıktı — iş eklemek bunu
yapamaz, yani fark gürültü. Tek koşuda gürültü tabanı ~±0.3ms, sayaçlar altında kalıyor.
Cache sayıları birebir aynı. Detay `BENCHMARKS.md`.

### Orijinal plan notu

Damage tracking'in temeli: bir `BufferLine`'ın değişip değişmediğini O(1) bilmek.

- `line.dart`'a `int _revision = 0` + `int get revision`.
- Tüm mutasyon noktalarında `_revision++`:
  `setForeground` / `setBackground` / `setAttributes` / `setContent` / `setWidth` /
  `setCodePoint` / `setCell` / `setCellData` / `setAsciiCells`,
  `eraseCell` / `eraseRange` / `resetCell`,
  `removeCells` / `insertCells`, `clearWideCellAt`, `_setUnderlineColor`,
  `addCombiningCharacter`, `resize`, `copyFrom`.
  Hepsi tek dosyada (`lib/src/core/buffer/line.dart`) — dışarıdan `_data`'ya yazan yok
  (#5'te kapatıldı, `data` deprecated).
- `Buffer`'a `viewportRevision`: scroll, resize, alt-screen geçişi, satır ekleme/silme bump'lasın.
- Test: her public mutator için "revision arttı" testi. Mekanik ama regresyona karşı tek koruma.

**Risk:** düşük. Davranış değişikliği yok, sadece sayaç.

---

## Faz 2 — `_paint()`'i pass'lere ayır — **TAMAMLANDI (2026-08-05)**

**Planın iki-pass şeması uygulanamaz.** Statik iş bitişik değil, dinamik overlay'ler
ortasına giriyor:

```
1. line backgrounds                                              ← STATİK
2. cursor-line hl, search bg, highlights, selection bg, block cursor  ← DİNAMİK
3. line foregrounds                                              ← STATİK
4. search fg, selection fg, underline, composing, diğer cursor    ← DİNAMİK
```

Overlay'ler arka planların üstüne, glyph'lerin altına düşmek zorunda. "Önce tüm statik,
sonra tüm dinamik" yapılırsa seçim arka planı metnin üstünü boyar. Sonuç: **Faz 3'ün satır
cache'i bir satırın bg+fg'sini tek `ui.Picture`'a kaydedemez** — iki ayrı kayıt, arasında
dinamik pass. Aşağıdaki `LinePictureCache` şeması (`value: ui.Picture // bg + fg`) bu
yüzden geçersiz, Faz 3'e girmeden düzeltilmeli.

Uygulanan bölme: `_paintSurface` (viewport clip'i dışındaki yüzey dolgusu) +
`_paintStaticBackgrounds` / `_paintOverlayBackgrounds` / `_paintStaticForegrounds` /
`_paintOverlayForegrounds`.

Cursor durumu frame başına bir kez `_resolveCursorPaintState()` ile çözülüp
`_CursorPaintState` içinde taşınıyor — üç pass de aynı değerleri istiyor ve her biri
buffer'dan cursor hücresini yeniden okuyordu. `invertsCell` / `invertedColumn` getter'ları
`shouldPaintBlockCursor && _focusNode.hasFocus` koşulunun dört ayrı tekrarını kaldırıyor.

**İki tuzak çözülmedi, belgelendi.** Faz 2'nin kabul kriteri "davranış aynı" olduğu için
`_paintStaticForegrounds` hâlâ `cursorColumn` ve `blinkVisible` alıyor. Planın önerdiği
"statik pass'te normal çiz, dinamik pass'te ters renkte üstüne yaz" çözümü davranışı
değiştirir: cursor dikdörtgeni statik fg'den önce çizildiği için normal glyph dikdörtgenin
üstüne düşer, ters glyph de onun üstüne — antialiasing'de alttaki sızar. Bu iş Faz 3'e ait.

Kabul kriteri sağlandı: 4 golden dahil 835 test yeşil, `dart analyze` temiz. Ölçüm iki
koşuda gürültü içinde. Bu faz ölçümün çözünürlük sınırını da ortaya çıkardı — `plain` UI
p50 dört koşuda 1.0/0.9/1.3/1.0 → **gerçek gürültü bandı ±0.5ms**, daha önce yazılan
±0.3ms fazla dardı. `BENCHMARKS.md`'de `fullscreen`'in dört koşuda tek yönlü tırmanışı da
not edildi; termal sürüklenmeden ayrılamadı.

### Orijinal plan notu

Şu an `_paint()` (`lib/src/ui/render.dart:750-935`) tek gövde: background, cursor-line
highlight, search, highlights, selection, cursor, foreground, underline. İçinde hem karar
hem çizim var.

Statik / dinamik ayrımı:

| Statik (buffer'a bağlı) | Dinamik (her frame değişebilir) |
|---|---|
| line backgrounds | cursor (blink fazı) |
| line foregrounds | selection |
| — | search highlight |
| — | cursor line highlight |
| — | composing text (IME) |

Kod: `_paintStaticContent(canvas, offset, first, last)` ve `_paintDynamicOverlays(...)`
diye ikiye böl. Bu fazda **davranış aynı kalsın**; golden testlerin değişmemesi kabul kriteri.

### İki tuzak

- **Block cursor altındaki hücre.** `paintLineForegrounds` şu an `cursorColumn` /
  `cursorForeground` alıp cursor altındaki karakteri ters renkte çiziyor — statik/dinamik
  ayrımını kirletiyor. Çözüm: statik pass'te normal çiz; dinamik pass'te cursor dikdörtgeni
  + o tek karakteri üstüne yeniden çiz. Tek hücrelik ekstra iş.
- **Yanıp sönen metin (`blinkVisible`).** Aynı sorun. Ya statik pass'te her zaman görünür
  çizip blink kapalı fazda üstünü arka plan rengiyle kapat, ya da (daha basit, blink nadir)
  blink içeren satırı statik cache'e hiç alma.

---

## Faz 3 — Satır bazlı `ui.Picture` cache — **YAPILDI, BİRLEŞTİRİLMEDİ**

`render-line-picture-cache` branch'inde duruyor. Kod çalışıyor ve hedefine ulaşıyor;
ölçüm birleştirmeye izin vermiyor.

**Ne yapıldı.** `lib/src/ui/line_picture_cache.dart` — satır başına iki `Picture`
(Faz 2'nin bulduğu sıralama kısıtı yüzünden tek değil), kimlik bazlı LRU,
`line.revision` ile invalidation, kayıt canvas origin'inde + replay'de `translate`.
Faz 2'nin işaretlediği üç kirlilik bypass'la çözüldü: cursor satırı, hover edilen
hyperlink, blink içeren satır (blink ancak çizerken öğrenildiği için kayıt yapılıp o
frame oynatılıyor sonra atılıyor; `blinkVisible` kayda gerçek değeriyle geçiyor).

**Hedefine ulaştı.** `static`: frame başına paragraph lookup 3514 → 95, UI p50
1.7ms → 0.4ms (%76). `fullscreen` beklendiği gibi %0 hit.

**Neden birleştirilmiyor.** UI'dan kazanılan her 1ms'e karşılık ~0.55ms raster
maliyeti geldi. UI ve raster ayrı thread ve frame'ler arasında pipeline'lı, yani
sürdürülebilir frame hızını yavaş olan belirliyor — ve cache dostu workload'larda
zaten yavaş olan raster'dı:

| workload | max(UI, raster) faz 2 → faz 3 |
|---|---|
| plain | 1.7 → **2.2** |
| boxdraw | 3.3 → 3.4 |
| fullscreen | 2.3 → 2.4 |
| static | 2.7 → **3.5** |

`static` ve `plain`'deki fark iki koşuda da tekrarlandı, gürültü değil. Tek frame
gecikmesi (UI + raster) olarak okunursa `static` 4.4 → 3.9 ile hafif iyileşiyor;
iki okuma da savunulabilir ve **ikisi de eyleme dönük değil**, çünkü hiçbir workload
16.7ms bütçesine yaklaşmıyor.

Sebep planın öngördüğü: 37 satır × 2 kayıt = frame başına 74 `drawPicture`, Skia tek
komut akışını çok sayıda küçük picture'dan daha iyi batch'liyor.

Planın bu faz için koyduğu kriter aynen buydu — *"Raster süresi artıp build süresi
düşerse net kazanç yok demektir → Faz 3 geri alınır."* Ölçüm bunu söylüyor.

Testler: `test/src/ui/line_picture_cache_test.dart` (6 test) branch'te kalıyor.

### Orijinal plan notu

Flutter'da kısmi repaint yok: `paint()` çağrıldığında canvas baştan derleniyor. Kaçış yolu,
satırın çizim komutlarını `ui.Picture` olarak kaydedip yeniden oynatmak.

```
LinePictureCache
  key:   (BufferLine identity, line.revision, cellSize, styleRevision, paletteRevision)
  value: ui.Picture   // (0,0) origin'de kaydedilmiş, tek satır: bg + fg
```

`_paintStaticContent` şuna dönüşür:

```dart
for (var i = first; i <= last; i++) {
  final pic = _linePictures.get(lines[i]) ?? _recordLine(lines[i]);
  canvas.save();
  canvas.translate(0, lineOrigin(i).dy);
  canvas.drawPicture(pic);
  canvas.restore();
}
```

Kazanç: değişmemiş satırda per-cell döngü, `getCellData`, palette lookup, paragraph cache
lookup — hepsi atlanıyor. Cursor blink'te CPU tarafı sıfıra yakın iş yapıyor. Scroll'da
satırlar hareket ediyor ama picture'lar aynen kullanılıyor.

Yapılacaklar:
- `LinePictureCache` — LRU, kapasite ≈ viewport satır sayısı × 3. Eviction'da `Picture.dispose()`.
- Invalidation: `cellSize`, `devicePixelRatio`, tema/palette, font değişimi. `_clearParagraphCache()`
  zaten bu noktaların hepsinde çağrılıyor (`lib/src/ui/painter.dart:185,194,224,232,376,383,387`)
  — aynı yerlere bağla.
- Kayıt: `PictureRecorder` + `Canvas`, sonra `endRecording()`.

### Riskler — bu faz ölçümü zorunlu kılıyor

- Picture başına satır boyu komut listesi bellekte kalıyor. 3× viewport ≈ 150 satır, kabul edilebilir.
- Çok sayıda `drawPicture` çağrısında Skia batching'i tek akış kadar iyi olmayabilir.
  Impeller'da genelde sorun değil ama **Faz 0 baseline'ına karşı ölçülecek**. Raster süresi
  artıp build süresi düşerse net kazanç yok demektir → Faz 3 geri alınır.
- `cat` senaryosunda tüm satırlar sürekli değişiyor: cache tamamen ıskalıyor, üstüne kayıt
  maliyeti biniyor. **Heuristik gerekli:** bir frame'de kirli satır oranı %50'yi geçerse
  picture cache bypass edilip doğrudan çizilsin.

---

## Faz 4 — Ölç, sonra karar ver — **CEVAPLANDI**

- **`drawAtlas`'a geçmenin anlamı var mı? Hayır, ve gerekçesi Faz 3'ün beklediğinden
  güçlü.** Faz 3 CPU (UI thread) tarafını gerçekten çözdü — `static`'te 1.7ms → 0.4ms.
  Geriye kalan maliyet raster thread'inde ve Faz 3 onu **artırdı**. Yani darboğaz
  hiçbir zaman glyph shaping/layout değildi; ne kadar CPU işi kaldırırsan kaldır,
  ölçülen sınır GPU tarafındaki çizim komutları. `drawAtlas` bu tarafta daha fazla,
  daha küçük çizim birimi üretme riski taşıyor — Faz 3'ün `drawPicture` ile çarptığı
  duvarın aynısı.
- **ASCII için paragraph'ı bypass etmek katkı sağlar mı? Ölçülebilir değil.** Paragraph
  cache hit oranı `plain` ve `static`'te zaten %100. Bypass edilecek iş cache hit
  maliyetinden ibaret ve o maliyet Faz 3'te tamamen kaldırıldığında bile frame'i
  hızlandırmadı.

**Kalan gerçek adaylar** (ikisi de render pipeline'ı dışında):

1. **`boxdraw` glyph cache miss'i.** En pahalı workload, hem UI hem raster'da
   (2.3ms / 3.3ms). Hit oranı %97.1 — kalan %2.9 her seferinde vector path'i yeniden
   kuruyor. Faz 3 branch'inde bu oran %75'e düştü, yani cache boyutu/anahtarı gerçekten
   dar. Küçük, hedefli, ölçülebilir.
2. **Flood 48 fps.** 32 MiB'lık akışta output frame pipeline'ını aç bırakıyor
   (70-75 MiB/s). Bu parse-per-write yolu; render tarafında yapılacak hiçbir şey
   düzeltmiyor. Ölçülen tek "bütçeyi zorlayan" davranış bu. **Faz 5'te ölçüldü ve
   ayrıştırıldı.**

Ayrıca `BENCHMARKS.md`'de iki açık ölçüm borcu var: `sgr` workload'ının viewport'u
takip edip etmediği, ve `fullscreen`'in koşular arası tek yönlü tırmanışının termal mi
gerçek mi olduğu.

---

## Faz 5 — Write path — **ÖLÇÜLDÜ, BİR DENEY REDDEDİLDİ (2026-08-29)**

Faz 4'ün ikinci adayı (`flood`, 48 fps) sahada doğrulandı. ShellVibe'da yerel PTY
üstünde vtebench koşarken pencere donuyor: vtebench 1 MiB'lık örnekleri 11–24ms'de
"drenaj edildi" diye raporluyor, 2 saniyede bitiyor, ama uygulama o sırada yanıt
vermiyor ve bitişten sonra da bir süre arkadan yetişiyor. Faz 4'ün dediği aynen
çıktı: render tarafında yapılacak hiçbir şey bunu düzeltmiyor.

**Not:** Bu ölçümlerin hiçbiri Flutter içermiyor. `bin/parse_bench.dart`, 170x50
grid, workload başına 32 MiB, 8 KiB chunk (bir PTY okumasının verdiği boyut),
`dart compile exe` ile derlenmiş.

### Taban — M-serisi, macOS

| workload | full | parser | buffer% | scrollback kapalı | grapheme kapalı |
|---|---|---|---|---|---|
| ascii | 102 | 431 | 76% | 173 | 104 |
| ascii-long-lines | 153 | 825 | 81% | 230 | 147 |
| sgr | **76** | **99** | 23% | 85 | 75 |
| utf8 | 59 | 265 | 78% | 86 | 69 |
| cyrillic | 83 | 296 | 72% | 140 | 83 |
| altscreen | 170 | 234 | 27% | 174 | 174 |

Birimler MiB/s; `buffer%`, tam yol süresinin parse olmayan kısmı.

### Taban ne söylüyor

1. **Escape parser çoğu yükte darboğaz değil.** `ascii`'de parser tek başına
   431 MiB/s, tam yol 102. Zamanın %76–81'i buffer yazımında. "Parser yavaş"
   teşhisi bu yükler için yanlış olurdu.
2. **SGR istisna.** Orada buffer sadece %23 — kalan %77 parser'ın kendisi, ve
   76 MiB/s ile en yavaş ikinci yol. Renkli çıktı gerçek kullanımda baskın
   olduğu için pratikte en çok ödenen yol bu.
3. **Scrollback tutmak pahalı.** Kapatınca ascii 102 → 173 (+%70), cyrillic
   83 → 140 (+%69), utf8 59 → 86 (+%46).

### Reddedilen deney — tahliye edilen satırları havuzlamak

**Hipotez.** Scroll'da her satır öne düşen bir satırı tahliye edip arkaya aynı
boyda yenisini allocate ediyor (`buffer.dart` `_newEmptyLine`). Geniş bir
grid'de her biri birkaç KiB'lık `Uint32List`, yani büyük bir dosyayı `cat`'lemek
heap'i dosyanın kendisinden çok daha fazla çalkalıyor. Tahliye edilen depolamayı
geri vermek steady state'i allocation'sız yapmalı. `IndexAwareCircularBuffer`'da
`onEvict` hook'u bu iş için zaten duruyor.

**Uygulama.** `Buffer`'da serbest liste (derinlik 64), `onEvict`'ten besleniyor,
`_newEmptyLine` aynı genişlikte satır varsa oradan alıyor; `BufferLine.
resetForReuse()` `_data`'yı `fillRange` ile sıfırlıyor, map'leri ve `isWrapped`'i
temizliyor. Anchor taşıyan satırlar havuza alınmıyor (bir seçim kenarı, arama
isabeti veya mark hâlâ o satırı gösteriyor olabilir).

**Sonuç: yaklaşık 2 kat yavaş.** ascii 102 → 52, utf8 59 → 32.

Temizlemeyi geçici olarak çıkarıp (o hâliyle yanlış, sadece ölçüm için) maliyet
ayrıştırıldı:

| workload | taban | havuz + temizleme | havuz, temizlemesiz |
|---|---|---|---|
| ascii | 102 | 52 | **147** |
| ascii-long-lines | 153 | 77 | **209** |
| sgr | 76 | 57 | 82 |
| utf8 | 59 | 32 | **84** |
| cyrillic | 83 | 42 | **131** |
| altscreen | 170 | 174 | 174 |

**Yani havuzlama fikri doğru, temizleme onu öldürüyor.** Geri dönüşümün kendisi
scroll ağırlıklı yüklerde %37–58 kazandırıyor.

**Kök neden.** Dart'ta taze bir `Uint32List` allocate etmek, mevcut birini
temizlemekten ucuz. VM taze tipli veriyi işletim sisteminin zaten sıfırladığı
sayfalardan veriyor, yani allocation'daki sıfırlama pratikte bedava; `fillRange`
ise soğuk ve halihazırda fault'lanmış birkaç KiB'ı gerçekten yazıyor. İki yol da
"aynı kadar sıfırlıyor", maliyetleri aynı değil.

**Bir daha denenirse.** Tam temizlemeden kaçınmak şart. Tek makul yol satır
başına "yazılmış en yüksek sütun" işareti tutup yalnızca o aralığı temizlemek —
tipik kısa shell satırlarında öder, tam genişlik çıktıda ödemez, yani kazanç
workload'a bağlı olur ve yine ölçülmeden birleştirilemez.

**Yan bulgu.** `BufferLine.anchors` her çağrıda `UnmodifiableListView` allocate
ediyor. Bu deneyde suçlu değildi (kaldırmak sayıyı 51 → 52 oynattı, gürültü),
ama sıcak bir yolda kullanılacaksa allocation yapmayan bir `hasAnchors` gerekir.

Kod `master`'a girmedi, branch silindi. Kalan değer bu kayıt.

---

## Faz 5.1 — Faz 5'in `parser` kolonu bozuktu — **ONARILDI (2026-08-29)**

Faz 5'in üç okumasından ikisi `bin/parse_bench.dart`'ın `parser` kolonundan
çıkarılmıştı. O kolon, ölçmek istediği şeyi ölçmüyordu.

### Kusur

Bench'in no-op handler'ı yalnızca `writeChar` ve `writeText`'i uyguluyor,
`EscapeHandler`'ın kalan 233 üyesini `noSuchMethod`'a düşürüyordu. Her çağrı bir
`Invocation` allocate ediyor ve argümanları kutuluyor. Dosyanın kendi gerekçesi
"escape sekansları bayt başına nadirdir" idi; aynı dosyadaki workload üreteçleri
bunu yalanlıyor:

| workload | handler çağrısının kaynağı | ~çağrı/MiB |
|---|---|---|
| ascii | satır başına `\r\n` → `carriageReturn` + `lineFeed` | 22.000 |
| utf8 | aynı | 34.000 |
| sgr | satır başına 6 SGR + 1 reset + `\r\n` | 50.000 |
| altscreen | satır başına CUP + SGR + SGR-reset | 16.000 |

Yani `parser` kolonu, gerçek `Terminal`'in hiç ödemediği bir harness maliyetini
parser'ın hesabına yazıyordu — ve `buffer% = 1 - full/parser` olduğu için aynı
maliyet `buffer%`'i de aşağı çekiyordu.

### Onarım

`bin/noop_escape_handler.dart`: 233 üyenin hepsi açıkça uygulanmış, `noSuchMethod`
yok. `script/gen_noop_handler.dart` dosyayı `handler.dart`'tan üretiyor.

`noSuchMethod`'un yokluğu bir tercih değil, mekanizmanın kendisi: `implements` var
ve `noSuchMethod` yokken, `handler.dart`'a yarın eklenecek bir üye bench'i sessizce
zehirlemek yerine analyzer hatası veriyor.

### Eski / yeni taban

Üçer koşunun medyanı, aynı makine ve oturum, `dart compile exe`.

| workload | full | parser eski → yeni | buffer% eski → yeni | scrollback | no-grapheme |
|---|---|---|---|---|---|
| ascii | 107 → 105 | 437 → **568** (+%30) | 76 → **82** | 173 → 171 | 105 → 107 |
| ascii-long-lines | 149 → 151 | 824 → **910** (+%10) | 82 → **84** | 230 → 227 | 148 → 149 |
| sgr | 76 → 77 | 99 → **121** (+%22) | 23 → **36** | 86 → 88 | 75 → 77 |
| utf8 | 58 → 59 | 267 → **333** (+%25) | 78 → **82** | 86 → 86 | 70 → 69 |
| cyrillic | 85 → 85 | 294 → **360** (+%22) | 71 → **76** | 140 → 139 | 83 → 86 |
| altscreen | 172 → 170 | 232 → **279** (+%20) | 26 → **39** | 174 → 175 | 174 → 175 |

**Kontrol:** `full`, `scrollback` ve `no-grapheme` gerçek `Terminal` handler'ını
kullanıyor, `noSuchMethod`'a hiç uğramıyorlardı — ve üç koşuda da kıpırdamadılar.
Değişikliğin yalnızca hedeflenen kolonu etkilediğinin kanıtı bu.

Gürültü notu: eski koşularda `sgr`'nin `full` değeri 69–77 arasında oynadı (%11),
`utf8`'in `no-grapheme` değeri 62–70. Yeni koşularda ikisi de daha kararlı. Tek
koşuya hâlâ güvenilmemeli.

### Artefaktın büyüklüğü

Kolon farkından geri çıkarılan `noSuchMethod` maliyeti:

| workload | Δ ms/MiB | çağrı/MiB | ns/çağrı |
|---|---|---|---|
| ascii | 0.53 | 22.000 | 24 |
| utf8 | 0.74 | 34.000 | 22 |
| sgr | 1.84 | 50.000 | 37 |
| altscreen | 0.73 | 16.000 | 44 |

Argümansız çağrılar 22–24 ns, argüman taşıyanlar 37–44 ns. `Invocation`
allocation'ı artı argüman kutulama ile tutarlı, ve artefaktın neden `sgr`'de
`ascii`'den ağır bastığını açıklıyor: hem daha sık, hem argümanlı.

### Faz 5'in üç okumasının revizyonu

1. **"Escape parser çoğu yükte darboğaz değil" — ayakta, hatta daha güçlü.**
   Buffer payı düz metinde %76–81 değil **%82–84**.
2. **"SGR istisna, buffer sadece %23" — yön doğru, büyüklük yanlış.** Gerçek sayı
   **%36**. SGR hâlâ en parser-ağırlıklı yük ve `parser` kolonu 121 MiB/s ile
   açık ara en yavaş parse yolu (sonraki en yavaş: altscreen 279), ama "kalan
   %77 parser'ın kendisi" ifadesi %64'e iniyor. Aynı düzeltme `altscreen`'i de
   %26'dan %39'a taşıyor.
3. **"Scrollback tutmak pahalı" — dokunulmadı.** Bu okuma `full` ve `scrollback`
   kolonlarından geliyor, ikisi de kusurdan etkilenmiyordu.

### `WRITE_PATH_BRIEF.md` bölüm 6'nın türetmesi

Brifing CSI karakteri başına ~23 ns çıkarmıştı. Düzeltilmiş sayılarla aynı türetme
~19 ns veriyor. Ama bu hâlâ bir **üst sınır**, ölçüm değil: kalan sürenin içinde
`ByteConsumer.consume()`'un yanı sıra `_csi.params.clear()`/`add()`,
`FastLookupTable` dispatch'i ve `_csiHandleSgr`'ın parametre yürüyüşü de var.
`consume()`'un gerçek payı hâlâ ölçülmedi.

### Bu tabandan çıkan aday sırası

1. **Satır havuzu, 2. deneme (sınırlı temizleme).** Ölçülmüş tavanı en yüksek olan
   aday, ve düzeltme onu güçlendirdi: buffer payı her yükte sanılandan büyük
   çıktı. Reddedilen deneyin "havuz, temizlemesiz" kolonu tavanı zaten veriyor
   (ascii 102 → 147).
2. **`ByteConsumer.consume()` ASCII fast path.** `byte_consumer.dart:31-42`;
   `_decodeCodePoint` ve `_codePointCodeUnitLength` aynı surrogate testini iki kez
   yapıyor ve `first < 0xd800` iken ikisinin de cevabı sabit. ~10 satır, rollback
   semantiği değişmiyor, `consume()` çağıran her yol kazanıyor. Aynı zamanda
   madde 3'ün ön elemesi: kazanç çıkmazsa CSI hipotezi tek ölçümle düşer.
3. **CSI parametre toplu tarama.** Önceliği düştü ama ölmedi. Yazmadan önce
   throwaway bir hack ile tavanı ölçmek şart — sekans başına 9.6 bayt ve 1–3
   haneli parametre koşuları toplu taramanın kurulum maliyetini zor amorti eder.

### Ölçüm gerektirmeyen iki kayıt

**Scrollback cezasının %63–93'ü satır allocation'ı.** Faz 5'in kendi iki
tablosundan, yeni ölçüm yapmadan:

| workload | taban | scrollback kapalı | havuz, temizlemesiz | ceza | geri alınan |
|---|---|---|---|---|---|
| ascii | 102 | 173 | 147 | 71 | 45 (%63) |
| cyrillic | 83 | 140 | 131 | 57 | 48 (%84) |
| utf8 | 59 | 86 | 84 | 27 | 25 (%93) |

Faz 5'in "scrollback maliyetinin ne kadarı GC promotion baskısı" açık sorusu böylece
büyük ölçüde cevaplı: allocation. Ve reddedilen havuz deneyi bunun kanıtı — fikir
yanlış değildi, temizleme stratejisi yanlıştı.

**Faz 5'in "kök neden" paragrafı bir hipotez, doğrulanmış değil.**
*(Faz 5.3 bunu ölçtü ve bu maddenin kendisini çürüttü: Faz 5'in açıklaması
doğruymuş, aşağıdaki satır boyutu ise yanlış — 680 değil 3072 bayt. Madde,
yanlış dönüşün kaydı olarak duruyor.)* "VM taze tipli veriyi OS'un sıfırladığı
sayfalardan verir" açıklaması 170 sütunluk bir satır (680 baytlık `Uint32List`)
için muhtemelen yanlış — o boyut new-space bump-pointer
allocation'ı ve Dart onu açıkça sıfırlıyor. Daha olası iki aday: önbellek konumu
(taze satır sıcak TLAB'de, havuzdan gelen satır uzun süre önce tahliye edilmiş ve
soğuk) ve `Uint32List.fillRange`'in AOT'ta memset'e intrinsify edilip edilmediği.
Ayrım pratik sonuç doğuruyor: OS-sayfası modeli doğruysa kısmi temizleme de
kaybeder, önbellek modeli doğruysa kazanır — çünkü kısa shell satırlarında
dokunulan aralık bir cache line'a sığar. 2. deneme bu ayrımı ölçmeden başlamamalı.

---

## Faz 5.2 — `consume()` ASCII fast path — **BİRLEŞTİRİLDİ (2026-08-29)**

Faz 5.1'in aday listesindeki 2. madde. Ölçüm pozitif çıktı, `master`'a aday.

**Değişiklik.** `ByteConsumer.consume()` her kod noktasında `_decodeCodePoint` ve
`_codePointCodeUnitLength`'i çağırıyordu; ikisi de aynı high-surrogate testini
tekrar çalıştırıp aynı cevaba varıyordu — surrogate çifti başlatmayan bir birim
tek kod birimidir ve kendi kod noktasıdır. Testi bir kez başta yapıp dönmek,
astral metin dışındaki her şeyi kapsıyor: CSI parametreleri, C0 kontrolleri,
Latin, Kiril, ve run scan'in toplayamadığı metnin kod-noktası yolu.

Yapı gereği eşdeğer: iki yardımcı da tam bu dalda `first` ve `1` döndürüyor.
Rollback etkilenmiyor, `_previousRuneOffset` surrogate olmayan için zaten
`offset - 1` veriyor.

**Ölçüm — dönüşümlü A/B, üçer round, medyan, MiB/s.** İlk deneme ardışık
koşuldu ve `consume()`'a girmeyen kolonlar da birlikte %4-8 düştüğü için atıldı;
o termal sürüklenmeydi. Dönüşümlü koşu bunu iki koşula eşit dağıtıyor.

| workload | full | parser | scrollback | no-grapheme |
|---|---|---|---|---|
| ascii | 105 → 106 | 567 → 579 (+%2.1) | 166 → 172 | 106 → 103 |
| ascii-long-lines | 152 → 152 | 916 → 922 (+%0.7) | 225 → 226 | 148 → 149 |
| **sgr** | 76 → **81** (+%6.6) | 121 → **133** (+%9.9) | 85 → 88 | 76 → **80** |
| utf8 | 58 → 59 (+%1.7) | 334 → 342 (+%2.4) | 86 → 86 | 69 → 69 |
| cyrillic | 85 → 85 | 348 → 364 (+%4.6) | 140 → 138 | 85 → 85 |
| **altscreen** | 171 → **178** (+%4.1) | 276 → **296** (+%7.2) | 174 → **182** | 175 → **182** |

Kazanç escape-ağırlıklı iki yükte toplanıyor — `consume()`'un gerçekten sıcak
olduğu yer orası. Düz metin çoğunlukla `printableTextRunLength` +
`consumeAsciiCodeUnits` toplu yolundan geçtiği için `consume()`'a az uğruyor.
24 hücrenin hiçbirinde regresyon yok.

Gürültü bandının üstünde olduğunun kanıtı: iki koşulun değerleri örtüşmüyor.
`sgr` full 76/76/77'ye karşı 80/81/82; `sgr` parser 120/121/122'ye karşı
132/133/133; `altscreen` parser 272/276/279'a karşı 296/296/300.

**Yeni taban.** Sonraki ölçümler bu tablodan başlar:

| workload | full | parser | buffer% | scrollback kapalı | grapheme kapalı |
|---|---|---|---|---|---|
| ascii | 106 | 579 | 82% | 172 | 103 |
| ascii-long-lines | 152 | 922 | 84% | 226 | 149 |
| sgr | 81 | 133 | 39% | 88 | 80 |
| utf8 | 59 | 342 | 82% | 86 | 69 |
| cyrillic | 85 | 364 | 77% | 138 | 85 |
| altscreen | 178 | 296 | 40% | 182 | 182 |

**Ön eleme sonucu.** Faz 5.1 bu adımı CSI hipotezinin ön elemesi olarak
koymuştu: `consume()`'dan kazanç çıkmazsa CSI toplu tarama tek ölçümle düşerdi.
Çıktı, yani CSI adayı ayakta — ama kalan tavan daraldı. Aynı türetme yeniden:
ascii parser 579 → 1.68 ns/metin-karakteri; sgr parser 133 → 7.52 ms/MiB, bunun
673k metin karakteri 1.13 ms, kalan 6.39 ms 375k CSI karakterine düşüyor →
**karakter başına en fazla ~17 ns** (Faz 5.1'de ~19 idi). Bu hâlâ üst sınır:
içinde `_csi.params.clear()`/`add()`, `FastLookupTable` dispatch'i ve
`_csiHandleSgr`'ın parametre yürüyüşü de var.

**Bir sonraki mikro adım.** `consume()` hâlâ `_queue.first`'e iki kez dokunuyor:
bir kez `_advancePastConsumedBlocks()` içinde, bir kez `_queue.first.data` ile.
Aktif bloğu bir alanda tutmak bunu tekleştirir, ama `add`/`rollback`/
`unrefConsumedBlocks`/`reset` yollarında geçersiz kılma gerektirdiği için bu
adımdan daha fazla invariant taşıyor. Ayrı ölçülmeli.

---

## Faz 5.3 — Satır havuzu, 2. deneme — **REDDEDİLDİ, UYGULANMADAN (2026-08-29)**

Faz 5.1'in aday listesinde 1. sıradaydı. Faz 5.1 aynı zamanda "2. deneme bu
ayrımı ölçmeden başlamamalı" diye kayıt düşmüştü. Ayrım ölçüldü, cevap hayır
çıktı, kod yazılmadı.

**Ölçüm aracı.** `script/line_reuse_probe.dart` — Flutter yok, xterm3 yok, saf
`Uint32List`. İki senaryo da aynı sayıda satırı canlı tutuyor, tek fark taze mi
geri dönüşmüş mü. `dart compile exe` ile derlenir.

### Önce iki düzeltme

**Satır 3072 bayt, 680 değil.** Faz 5.1'de `_calcCapacity`'yi atlayıp doğrudan
sütun sayısından hesaplamışım. Doğrusu: `viewWidth` 170 →
`_calcCapacity(170) = 192` → `Uint32List(192 * 4)` = 768 word = **3072 bayt**.
`BENCHMARKS.md`'nin ilk metni ("clearing 3 KiB by hand") baştan doğruymuş.

**Faz 5'in kök nedeni doğruymuş.** Faz 5.1 onu "hipotez, muhtemelen yanlış" diye
işaretledi ve yerine önbellek konumu açıklamasını önerdi. O düzeltme yanlıştı ve
yanlış satır boyutuna dayanıyordu. Ölçülen, 3072 baytlık satır başına:

| iş | ns/satır | ns/word |
|---|---|---|
| allocate | 92 | **0.12** |
| indexed store döngüsü | — | **0.475** |
| `fillRange` | — | **1.6** |

Allocate etmek, word'leri gerçekten yazan en ucuz şeyden **4 kat ucuz**. Yani
allocation o word'leri yazmıyor. Faz 5'in "VM taze tipli veriyi zaten sıfır olan
sayfalardan veriyor" açıklaması ayakta.

### Asıl sonuç

ns/satır, düşük olan iyi. `written` = satırın gerçekten metin tuttuğu hücre
sayısı, kapasite 192. `loop-tail` = yalnızca yeni yazma sınırı ile eski "en
yüksek yazılmış sütun" işareti arasını temizle — yazmanın kendisi öncesini zaten
kapsadığı için Faz 5'in önerdiği tasarımın en iyi hâli bu.

| written | alloc | fill-all | fill-written | loop-written | loop-tail | sonuç |
|---|---|---|---|---|---|---|
| 30 | 153 | 1287 | 251 | 161 | 197 | berabere |
| 60 | 199 | 1323 | 492 | 307 | 242 | **alloc %22 önde** |
| 120 | 304 | 1445 | 988 | 611 | 340 | alloc %12 önde |
| 192 | 450 | 1565 | 1565 | 1023 | 355 | havuz %27 önde |

(depth 64; 8 ve 512 derinlikleri aynı tabloyu veriyor, yani sonuç havuz
derinliğine duyarsız.)

Havuz yalnızca **tam genişlikte** kazanıyor — ve orada kazanmasının sebebi
temizlenecek bir şey kalmaması, yani kazandığı şey tam olarak allocation'ın 92
ns'i. Gerçek shell çıktısının yoğunlaştığı orta genişliklerde kaybediyor.
Faz 5'in "tipik kısa shell satırlarında öder" öngörüsü tersine çıktı: kısa
satırda temizlenecek kuyruk **uzun**, çünkü altındaki satır ondan genişti.

**Karar: satır havuzu kapandı.** İki farklı temizleme stratejisiyle iki kez
ölçüldü. Faz 5'in kapanış cümlesi geçerliliğini koruyor: scroll maliyetine
yönelen bir şey, allocate edilen satırların **sayısını** ya da **boyutunu**
azaltmalı, onları yeniden kullanmayı denememeli.

Bu, Faz 5.1'in "scrollback cezasının %63-93'ü satır allocation'ı" tespitini
geçersiz kılmıyor — tespit doğru, ama o allocation'ın kendisi zaten ucuz; pahalı
olan onu geri dönüştürmek. Cezanın geri kalanı GC tarama basıncı ve satır
nesnelerinin kendisi, ve oraya ulaşan yol havuzlamadan geçmiyor.

### Yan bulgu — burada uygulaması yok

`Uint32List.fillRange`, indexed store döngüsünün **3.4 katı** (1.6'ya karşı
0.475 ns/word). AOT'ta memset'e inmiyor. xterm3 için kaldıraç değil:
`BufferLine.eraseRange` zaten hücre bazlı `eraseCell` döngüsü kullanıyor, ve
`lib/`'deki diğer `fillRange` çağrıları `tabs.dart`'ta reset başına bir kez ve
`unicode_v11.dart`'ta tek seferlik tablo kurulumunda. Kayda geçiyor ki bir gün
sıcak bir yola `fillRange` yazılmasın.

---

## Faz 5.4 — CSI parametre toplu tarama — **REDDEDİLDİ (2026-08-29)**

`WRITE_PATH_BRIEF.md`'nin ilk yazımında tek somut aday olarak sunulan fikir.
Faz 5.1 onu üçüncü sıraya düşürmüştü, Faz 5.2 ön elemeden geçirmişti. İki farklı
uygulamayla ölçüldü, ikisi de negatif. Kod `master`'a girmedi.

### Önce sıfır riskli bir şey denendi: dal sırası

`_consumeCsi`'nin döngüsünde rakam testi zincirin 7. sırasındaydı. CSI parametre
baytlarının ~%65'i rakam ve rakamlar (0x30-0x39) önceki dalların hiçbiriyle
eşleşemez — 0x18/0x1a değil, ESC/C1 değil, `< 0x20` değil, `;`/`:` değil. Testi
taşma kontrolünün hemen ardına almak semantik olarak birebir aynı.

**Sonuç: etkisi yok.** sgr parser 133 → 132, altscreen parser 297 → 299; ikisi de
gürültü içinde, değer kümeleri örtüşüyor. Dal zinciri maliyet değilmiş — iyi
tahmin edilen dört karşılaştırma ölçülebilir bir şey tutmuyor. Nötr ölçüm
birleşmez, geri alındı.

Bu, asıl aday için de bilgi: CSI döngüsündeki bayt başına maliyet dallarda değil.

### Deneme 1 — `digitRunLength` + toplu ilerletme

`ByteConsumer`'a `printableTextRunLength`'in ikizi bir `digitRunLength` eklendi;
`_consumeCsi` rakam görünce koşunun kalanını tarayıp `consumeAsciiCodeUnits` ile
tek seferde ilerletiyor. Blok sınırı kendiliğinden doğru (getter bloğun sonunda
duruyor), taşma tek bir `min` ile korunuyor.

| | sgr full | sgr parser | altscreen full | altscreen parser |
|---|---|---|---|---|
| taban | 80 | 131 | 179 | 299 |
| deneme 1 | **74** | **115** | **166** | **267** |

**%12'ye varan regresyon.** Sebep görünür: koşu başına dört ayrı
`_advancePastConsumedBlocks()` çağrısı (`digitRunLength`, `currentBlock`,
`currentCodeUnitOffset`, `consumeAsciiCodeUnits`) ve rakamların iki kez okunması
— bir kez taramak, bir kez toplamak için.

### Deneme 2 — tarama ve toplama tek geçişte

Reddetmeden önce en güçlü hâli. `digitRunLength` tamamen kaldırıldı; parser bloğu
bir kez alıp tek döngüde hem tarıyor hem `param`'a topluyor, sonra tek
`consumeAsciiCodeUnits`. Bir geçiş, üç `_advancePastConsumedBlocks`.

| | sgr full | sgr parser | altscreen full | altscreen parser |
|---|---|---|---|---|
| taban | 81 | 132 | 179 | 298 |
| deneme 2 | **77** | **121** | **170** | **278** |

Daha iyi ama hâlâ **%8.3 regresyon**. Değer kümeleri ayrık (sgr parser 131/132/132'ye
karşı 121/120/121), yani gürültü değil.

### Neden — ve Faz 5.2 ile bağlantısı

Faz 5.2'den sonra `consume()` zaten ucuz: ortak durumda tek karşılaştırmalık bir
`_advancePastConsumedBlocks()`, bir `_queue.first.data`, bir `codeUnitAt`, dört
alan güncellemesi. Toplu yol bunlardan `run` tanesini şununla değiştiriyor: bir
`isEmpty` kontrolü, iki getter (her biri kendi `_advancePastConsumedBlocks`'u
ile), `limit`/`headroom` hesabı, tarama döngüsü, ve `consumeAsciiCodeUnits` (bir
`_advancePastConsumedBlocks` daha artı sınır kontrolü).

sgr'de sekans başına ortalama 9.6 bayt ve parametre koşuları 1-3 haneli; ilk
rakam zaten `consume()` ile alındığı için toplu yola kalan ortalama ~1.5 rakam.
Kurulum bunu amorti etmiyor.

Faz 5.1'in notu bunu öngörmüştü: *"sekans başına 9.6 bayt ve 1-3 haneli parametre
koşuları toplu taramanın kurulum maliyetini zor amorti eder."* Ölçüm bunu
doğruladı ve bir şey daha ekliyor: **Faz 5.2 bu adayın hedeflediği boşluğu zaten
kapatmıştı.** İki sonuç bağımsız değil — `consume()` ucuzladıkça etrafında
toplu iş yapmanın anlamı kalmıyor.

### Fuzzer bir hata yakaladı

Deneme 2'nin ilk hâli `_queue.currentBlock`'u korumasız çağırıyordu; tüketilen
rakam chunk'ın son baytıysa kuyruk boşalıyor ve `_queue.first` `StateError: No
element` atıyor. `test/src/core/escape/parser_fuzz_test.dart` bunu üç ayrı seed
ile yakaladı. (Deneme 1'de aynı koruma `digitRunLength` içindeydi.) Kayda
geçiyor: CSI döngüsünde `consume()` sonrası kuyruğun boşalabileceği varsayılmalı.

### Cephenin durumu

Faz 5.1'in üç adayının üçü de kapandı: satır havuzu reddedildi (Faz 5.3),
`consume()` fast path birleştirildi (Faz 5.2), CSI toplu tarama reddedildi
(bu faz). `Terminal.write` üzerinde kalan bilinen mikro adım
`consume()` içindeki çift `_queue.first` erişimi; ondan sonrası Faz 6.

---

## Faz 6 — Scrollback maliyetinin kaynağı — **ÖLÇÜLDÜ, UYGULANMADI (2026-08-29)**

Faz 6 "flood altında ileri sarma" olarak açılmıştı. Ölçüm cepheyi yeniden
çerçeveledi: hedeflenen maliyetin kaynağı bulundu ve ona kayıpsız, API'siz bir
yoldan saldırılabiliyor. Flood fikri aşağıda Faz 7 adayına indi.

**Araçlar.** `script/scrollback_cost_probe.dart` ve
`script/trim_variant_probe.dart` — Flutter yok, xterm3 yok, saf `Uint32List`.

### Kaynak: canlı küme, allocation değil

`parse_bench`'in `scrollback` kolonu `maxLines: 0` ile koşuyor, ama
`buffer.dart:81` bunu `max(maxLines, viewHeight)`'a genişletiyor. Yani ring
hâlâ 50 satır, scroll başına allocation aynı, tahliye muhasebesi aynı. Tek
değişen: canlı satır sayısı 50 mi 10000 mü.

`ascii`'de o kolon satır başına 328 ns ediyor. Faz 5.3 allocation'ı tek başına
92 ns ölçmüştü. Kalan 236 ns nerede?

| depth | canlı | w=30 | w=60 | w=120 | w=192 |
|---|---|---|---|---|---|
| 50 | 0 MB | 151 | 174 | 274 | 388 |
| 200 | 1 MB | 144 | 180 | 283 | 400 |
| 1000 | 3 MB | 169 | 203 | 307 | 424 |
| 4000 | 12 MB | 285 | 326 | 415 | 533 |
| 10000 | 29 MB | **561** | 629 | 767 | 814 |

Canlı küme sürüklüyor. 30 sütun yazan bir satır 50 canlıyken 151 ns, 10000
canlıyken 561 ns. Bu, GC'nin her satırın 3072 baytlık backing store'unu old
space'e terfi ettirirken yaptığı kopya — ve kopya store'un boyutuyla orantılı,
içindeki metinle değil.

**Yani kaldıraç satırların sayısı değil boyutu.** Faz 5'in kapanış cümlesi
tam bunu söylüyordu ("allocate edilen satırların sayısını **ya da boyutunu**
azaltmalı") ve boyut yarısı hiç denenmemişti.

Aynı satırlar, `_calcCapacity`'nin yazılan genişlik için vereceği kapasiteyle
(taban 64) allocate edilirse, derinlik 10000'de:

| yazılan | kapasite | bugün | doğuştan küçük | kazanç |
|---|---|---|---|---|
| 30 | 64 | 561 | **180** | 3.1× |
| 60 | 96 | 629 | **345** | 1.8× |
| 120 | 128 | 767 | **590** | 1.3× |

Yan kazanç: 10000 satırlık scrollback şu an 30 MB tutuyor; gerçekçi bir shell
çıktısı karışımında bu ~10-15 MB'a iner. ShellVibe mobilde ayrıca değerli.

### Reddedilen form: viewport'tan çıkarken trim

Fikrin belirgin hâli ve blast radius'u en dar olanı: satır viewport'ta tam
kapasitede yaşar, scrollback'e düşerken yazılan genişliğine kopyalanır. Yazma
yoluna hiç dokunmaz, render zaten `line.length` ile dönüyor
(`painter.dart:494`, `:580`, `:309`), `getText` sıfır codepoint'li hücreleri
atladığı için çıktı değişmez, ve `Buffer.resize` (`buffer.dart:1672`) pencere
değişiminde satırları zaten `newWidth`'e büyütüyor. Yani uygulanabilirliği
temizdi.

**Ölçüm her hücrede negatif çıktı.**

| depth | yazılan | bugün | trim | doğuştan küçük |
|---|---|---|---|---|
| 1000 | 30 | 171 | 224 (−%24) | 79 |
| 1000 | 95 | 248 | 336 (−%26) | 186 |
| 4000 | 60 | 317 | 396 (−%20) | 181 |
| 10000 | 30 | 544 | 601 (−%10) | 181 |
| 10000 | 95 | 646 | 819 (−%21) | 394 |
| 10000 | 120 | 691 | 970 (−%29) | 581 |

Aritmetik basit: trim, promotion'da kazandığı ~250 ns'i geri vermek için küçük
bir allocate artı kopya ödüyor ve o ikisi aynı büyüklük mertebesinde. **Kazancı
veren şey büyük store'u geri vermek değil, hiç allocate etmemek.**

Bu form kapandı. Kayda geçiyor çünkü fikrin en cazip görünen hâli bu ve biri
tekrar uzanmadan önce ölçüldüğünü bilmeli.

### Açık aday: doğuştan küçük satır

Ölçülmüş tavan 1.2–3.0×. Uygulanmadı.

Taslak: satır `_calcCapacity`'nin tabanı olan 64 hücreyle doğar; büyütme
`line.dart`'ın yazma metotlarının içinde olur (`setAsciiCells`, `setCell`,
`eraseRange`, `insertCells`, `copyFrom` — her biri yazacağı aralık için
kapasite garantiler), böylece `Buffer` hiç değişmez ve
`_data.length == _calcCapacity(_length) * _cellSize` invariant'ı korunur —
okuma yolunda hiçbir kontrol gerekmez.

Bilinen riskler:
- Sıcak yazma yolunda kapasite karşılaştırması: `setAsciiCells`'te çağrı
  başına bir tane (ucuz), `setCell`'de hücre başına bir tane (kod-noktası
  yolu, ölçülmeli).
- Geniş satırlarda büyütme kopyaları. `_calcCapacity` bilerek doubling
  yapmıyor (`line.dart:745` yorumu: doubling throughput'u kötüleştirmişti), yani
  büyüme adımı 32 hücre ve tam genişlik bir satır birkaç kopya ödeyebilir.
- `altscreen` her satırı tam genişlik yazıyor; orada net kayıp olabilir.
  Satırlar bir kez büyüyüp öyle kaldığı için muhtemelen tek seferlik, ama
  ölçülmeden bilinmez.

Adım adım ölçülmeli: önce kapasite muhasebesi tek başına (davranış değişmeden,
sıcak yol maliyetini görmek için), sonra küçük doğum.

---

## Faz 7 adayı — flood altında ileri sarma — **PREMİSİ ÇÜRÜDÜ (2026-08-30)**

Saha semptomu (ShellVibe'da vtebench sırasında donma) write hızıyla kapanmıyor,
ve bu aritmetikle görülebiliyor: vtebench 1 MiB'ı 11–24 ms'de boşaltıyor, yani
40–90 MiB/s süregelen üretim; `Terminal.write` sgr'de 77 MiB/s. Write'ı %30
hızlandırmak, kuyruğu sınırsız olan bir sistemde donmayı gidermez, geciktirir.

`PacedTerminalWriter` bunu kendi dokümanında söylüyor
(`lib/src/ui/paced_writer.dart:28-31`): backpressure yok, bekleyen chunk'lar parse
edilene kadar tutuluyor. Not: Faz 5'teki "uygulama tarafında düzeltilemez" ifadesi
`flutter_pty`'nin **public Stream API'si** için doğru; native okuma tarafının
değiştirilemeyeceği anlamına gelmiyor, o kapı ölçülmedi.

xterm3 içinde kalan kaldıraç diye şu önerilmişti: backlog bir eşiği aştığında
scrollback'e yazmayı, reflow'u ve anchor bakımını atlayan bir mod — o satırlar
nasılsa viewport'a hiç girmeden kayacak. Tavanı `scrollback` kolonundan
türetilmişti: ascii'de +%63, cyrillic'te +%64.

**O tavan bu moda ait değil.** `scrollback` kolonu `maxLines: 0` ile koşuyor,
ki `buffer.dart:81` bunu `max(maxLines, viewHeight)` = 50'ye genişletiyor.
İki koşu arasındaki tek fark canlı satır sayısı — 50'ye karşı 10000 — ve
`IndexAwareCircularBuffer.push` bu iki durumda **aynı** işi yapıyor. Dahası
derinlik 10000'de daha *az*: ring dolana kadar hiç tahliye yok, yani `onEvict`
ve hyperlink budaması hiç çalışmıyor. Daha az iş yapıp daha yavaş koşuyor,
çünkü fark iş miktarında değil, GC'nin canlı tuttuğu kümede.

Sonuç: **geçmişi koruyan bir ileri sarma modu o farkın hiçbirini toplayamaz.**
Fark, scrollback'i tutmanın fiyatı; modu açmak satırları yine tutmayı gerektirir.
Toplayabilmesinin tek yolu geçmişi düşürmek olurdu, ki o bir performans modu
değil, veri kaybı kararıdır.

O farka saldırabilen tek şey satırın **boyutu**, ve Faz 6.1 tam olarak onu yaptı.
Ölçüldü: Faz 6.1 sonrası `full`/`scrollback` açığı ascii'de %41 → %32,
utf8'de %30 → %15, cyrillic'te %40 → %30. Yani tavanın bir kısmı zaten
toplandı ve kalanı da aynı cepheye ait, ileri sarmaya değil.

Saha semptomu için kalan cevap değişmiyor ve xterm3'ün içinde değil: üretici
sınırsızsa `Terminal.write`'ı hızlandırmak donmayı geciktirir, gidermez.
ShellVibe bunu okuma tarafına backpressure koyarak çözdü (kendi isolate'inde,
64 KiB/4 ms batch, dört batch kredi) — `PacedTerminalWriter`'ın dokümanının
zaten söylediği yer (`lib/src/ui/paced_writer.dart:28-31`).

---

## Sıralama ve risk

| Faz | İş | Bağımlılık | Risk |
|---|---|---|---|
| 0 | Benchmark harness | — | **`master`'da** |
| 1 | Line revision counter | — | yapıldı, branch'te kaldı (tüketicisi yok) |
| 2 | Pass ayrımı (davranış sabit) | 0 | **`master`'da** |
| 3 | Line picture cache | 1, 2 | yapıldı, branch'te kaldı (ölçüm negatif) |
| 4 | Ölçüm + karar | 0, 3 | cevaplandı |
| 5 | Write path ölçümü | 0 | ölçüldü; satır havuzu reddedildi (ölçüm negatif) |
| 5.1 | `parser` kolonunun onarımı | 5 | **`master`'a aday** — `lib/` değişmedi |
| 5.2 | `consume()` ASCII fast path | 5.1 | **`master`'a aday** — sgr +%6.6, regresyon yok |
| 5.3 | Satır havuzu, 2. deneme | 5.1 | **reddedildi** — uygulanmadan ölçüldü, kapandı |
| 5.4 | CSI parametre toplu tarama | 5.2 | **reddedildi** — iki uygulama, ikisi de negatif |
| 6 | Scrollback maliyetinin kaynağı | 5.1 | ölçüldü; trim reddedildi, doğuştan küçük açık aday |
| 7 | Flood altında ileri sarma | 6 | önerildi, ölçülmedi |

Faz 5.1, 5.3, 5.4 ve 6 `lib/` altına hiç dokunmadı — üçü ölçüm ve kayıt, biri
uygulanmadan reddedilen bir aday. `lib/`'i değiştiren tek faz 5.2. Faz 7 bilerek
ertelendi; Faz 6 aynı maliyete kayıpsız ve API'siz bir yoldan saldıracak bir aday
bıraktığı için önceliği düştü.

`master` Faz 0 ve Faz 2'yi aldı — ölçüm altyapısı ve davranış değiştirmeyen pass
ayrımı. Faz 1 ve Faz 3 `render-line-picture-cache` branch'inde duruyor.
**Faz 0 ve 2'nin ölçülebilir performans kazancı yok ve olması da beklenmiyordu;**
biri enstrümantasyon, diğeri saf refactor. Değerleri şurada: Faz 0 olmasa Faz 3'ü
kanıtla reddedemez, "UI %76 düştü" diye birleştirip frame'i sınırlayan sayıyı
kötüleştirirdik.

- Faz 0 ve 1 paralel gidebilir, ayrı worktree.
- Faz 2 ve 3 sıralı, aynı dosyalara dokunuyor → tek worktree.
- Her faz ayrı commit; `dart analyze` sıfır uyarı + `flutter test` tamamen yeşil.
- Faz 3 ayrı branch'te kalsın; ölçüm olumlu çıkmadan `master`'a girmesin.

---

## Açık öncelik sorusu

`CODE_REVIEW_VERIFIED.md`'de en üstteki açık madde hâlâ **mobil IME**. Bu render planı
onunla çakışmıyor, ama render işi ölçüme göre değersiz çıkabilir; IME ise kesin bir bug.
Sıralama kararı verilmedi.
