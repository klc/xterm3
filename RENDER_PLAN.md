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

**Faz 5'in "kök neden" paragrafı bir hipotez, doğrulanmış değil.** "VM taze tipli
veriyi OS'un sıfırladığı sayfalardan verir" açıklaması 170 sütunluk bir satır
(680 baytlık `Uint32List`) için muhtemelen yanlış — o boyut new-space bump-pointer
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

## Faz 6 adayı — flood altında ileri sarma — **ÖNERİLDİ, ÖLÇÜLMEDİ**

Saha semptomu (ShellVibe'da vtebench sırasında donma) write hızıyla kapanmıyor,
ve bu aritmetikle görülebiliyor: vtebench 1 MiB'ı 11–24 ms'de boşaltıyor, yani
40–90 MiB/s süregelen üretim; `Terminal.write` sgr'de 77 MiB/s. Write'ı %30
hızlandırmak, kuyruğu sınırsız olan bir sistemde donmayı gidermez, geciktirir.

`PacedTerminalWriter` bunu kendi dokümanında söylüyor
(`lib/src/ui/paced_writer.dart:28-31`): backpressure yok, bekleyen chunk'lar parse
edilene kadar tutuluyor. Not: Faz 5'teki "uygulama tarafında düzeltilemez" ifadesi
`flutter_pty`'nin **public Stream API'si** için doğru; native okuma tarafının
değiştirilemeyeceği anlamına gelmiyor, o kapı ölçülmedi.

xterm3 içinde kalan kaldıraç: backlog bir eşiği aştığında scrollback'e yazmayı,
reflow'u ve anchor bakımını atlayan bir mod — o satırlar nasılsa viewport'a hiç
girmeden kayacak. Tavanı zaten ölçülü: `scrollback` kolonu ascii'de +%63,
cyrillic'te +%64.

Bu round'un dışında bırakıldı: API yüzeyi kararı gerektiriyor, ve mikro-optimizasyon
ölçümleriyle aynı anda gitmesi ikisinin de gürültüsünü karıştırır.

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
| 6 | Flood altında ileri sarma | 5.1 | önerildi, ölçülmedi |

Faz 5.1 yalnızca `bin/` ve `script/`'e dokunuyor, `lib/` altında hiçbir değişiklik
yok — ürün riski sıfır, çıktısı karar verilebilir sayılar. Faz 6 bilerek ertelendi.

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
