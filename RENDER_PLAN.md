# xterm2 — Render pipeline planı

**Tarih:** 2026-08-05 · **Taban:** `master` @ `ccb2ce4`
**Kaynak:** `chatgpt_xterm2_conversation.md` incelemesi + kod doğrulaması

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
   düzeltmiyor. Ölçülen tek "bütçeyi zorlayan" davranış bu.

Ayrıca `BENCHMARKS.md`'de iki açık ölçüm borcu var: `sgr` workload'ının viewport'u
takip edip etmediği, ve `fullscreen`'in koşular arası tek yönlü tırmanışının termal mi
gerçek mi olduğu.

---

## Sıralama ve risk

| Faz | İş | Bağımlılık | Risk |
|---|---|---|---|
| 0 | Benchmark harness | — | **`master`'da** |
| 1 | Line revision counter | — | yapıldı, branch'te kaldı (tüketicisi yok) |
| 2 | Pass ayrımı (davranış sabit) | 0 | **`master`'da** |
| 3 | Line picture cache | 1, 2 | yapıldı, branch'te kaldı (ölçüm negatif) |
| 4 | Ölçüm + karar | 0, 3 | cevaplandı |

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
