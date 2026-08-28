# xterm3 — Write path throughput brifingi

**Tarih:** 2026-08-29 · **Taban:** `master` @ `1537440` (release 6.1.3)
**Amaç:** `Terminal.write` yolunun neden yavaş kaldığını, nelerin ölçüldüğünü ve
nelerin denenip reddedildiğini tek dosyada devretmek.

Bu dosya bir çözüm önerisi değil, bir problem tanımı. Aşağıdaki tek somut aday
(CSI toplu tarama) **ölçülmemiş bir hipotez**; en iyi yol olduğu iddia edilmiyor.

---

## 1. Sorun

`Terminal.write` yolu, bir PTY'nin ürettiği hızın altında kalıyor.

Sahadaki görünümü: ShellVibe'da (Flutter uygulaması, xterm3 6.1.3) yerel PTY
üzerinde vtebench koşarken pencere donuyor. vtebench 1 MiB'lık örnekleri 11–24 ms'de
"boşaltıldı" diye raporluyor ve tüm koşuyu 2 saniyede bitiriyor; uygulama o sırada
yanıt vermiyor ve vtebench çıktıktan **sonra da** bir süre arkadan yetişiyor.

Uygulama tarafında düzeltilemeyeceği doğrulandı. `flutter_pty` çıktıyı bir
`ReceivePort` ile veriyor:

```dart
Stream<Uint8List> get output => _stdoutPort.cast();
```

PTY'yi native bir thread okuyup porta mesaj gönderiyor. Dart tarafında
`subscription.pause()` çağırmak o thread'e ulaşmıyor, yani Dart'tan PTY'ye giden
bir backpressure yolu yok. xterm3'ün kendi `PacedTerminalWriter`'ı da dokümanında
bunu söylüyor: *"There is no back pressure — pending chunks are held until they
can be parsed."* Üretici tüketiciden hızlı olduğu sürece kuyruk büyüyor, frame
callback'i PTY mesajlarının arkasında sıra bekliyor.

Geriye tek gerçek kaldıraç kalıyor: **`Terminal.write`'ın kendi hızı.**

---

## 2. Bu sorun repoda zaten kayıtlı

`RENDER_PLAN.md`, Faz 4, "kalan gerçek adaylar", madde 2:

> **Flood 48 fps.** 32 MiB'lık akışta output frame pipeline'ını aç bırakıyor
> (70-75 MiB/s). Bu parse-per-write yolu; render tarafında yapılacak hiçbir şey
> düzeltmiyor. Ölçülen tek "bütçeyi zorlayan" davranış bu.

`RENDER_PLAN.md` Faz 5 bu brifingdeki ölçümlerin ve reddedilen deneyin kaydını
tutuyor.

---

## 3. Render darboğaz DEĞİL — kapanmış soru

Faz 0–4 bunu ölçtü ve kapattı. Ajan render tarafına yönelmemeli.

- Hiçbir workload 16.7 ms frame bütçesine yaklaşmıyor. En kötü p99: **2.8 ms UI /
  3.6 ms raster**.
- Faz 1 (satır revizyon sayacı) ve Faz 3 (satır bazlı `ui.Picture` cache)
  yazıldı, çalışıyor, ama **ölçüm negatif olduğu için birleştirilmedi**. Faz 3
  `static` workload'ında UI p50'yi 1.7 ms → 0.4 ms (%76) düşürdü, karşılığında
  raster'ı yükseltti — ve sürdürülebilir frame hızını zaten yavaş olan raster
  belirliyordu. `render-line-picture-cache` branch'inde duruyorlar.
- Faz 4, `drawAtlas`'a geçme sorusunu **hayır** diye cevapladı: Faz 3 CPU tarafını
  gerçekten çözdüğü hâlde frame hızlanmadı, yani sınır hiçbir zaman glyph
  shaping/layout değildi.

---

## 4. Ölçüm aracı

`bin/parse_bench.dart` — Flutter yok, renderer yok, saf write yolu. 170x50 grid,
workload başına 32 MiB, 8 KiB chunk (bir PTY okumasının verdiği boyut).

```sh
dart compile exe bin/parse_bench.dart -o /tmp/parse_bench && /tmp/parse_bench
```

JIT (`dart run`) sayıları ürünle karşılaştırılabilir değil; derleyerek çalıştır.

Kolonlar:

- `full` — `Terminal.write`, 10000 satır scrollback
- `parser` — aynı baytlar `EscapeParser`'dan, hiçbir şey yapmayan handler ile
- `buffer%` — tam yol süresinin parse olmayan kısmı
- `scrollback` — `maxLines: 0` ile `Terminal.write`
- `no-grapheme` — DEC mode 2027 kapalı

---

## 5. Taban ölçüm

M-serisi macOS, MiB/s:

| workload | full | parser | buffer% | scrollback kapalı | grapheme kapalı |
|---|---|---|---|---|---|
| ascii | 102 | 431 | 76% | 173 | 104 |
| ascii-long-lines | 153 | 825 | 81% | 230 | 147 |
| **sgr** | **76** | **99** | **23%** | 85 | 75 |
| utf8 | 59 | 265 | 78% | 86 | 69 |
| cyrillic | 83 | 296 | 72% | 140 | 83 |
| altscreen | 170 | 234 | 27% | 174 | 174 |

### Üç okuma

1. **Escape parser çoğu yükte darboğaz değil.** `ascii`'de parser tek başına
   431 MiB/s, tam yol 102. Zamanın %76–81'i buffer yazımında. "Parser yavaş"
   teşhisi bu yükler için yanlış olur.
2. **SGR istisna.** Orada buffer sadece %23 — kalan %77 parser'ın kendisi ve
   76 MiB/s ile en yavaş ikinci yol. Gerçek CLI çıktısı (renkli prompt,
   `ls --color`, build log'ları, `htop`) SGR ağırlıklı olduğu için pratikte en
   çok ödenen yol budur.
3. **Scrollback tutmak pahalı.** Kapatınca ascii 102 → 173 (+%70), cyrillic
   83 → 140 (+%69), utf8 59 → 86 (+%46).

---

## 6. Bulunan somut nokta — doğrulanmış, çözülmemiş

`sgr` payload'ının **%35.8'i** CSI baytı (sayılarak ölçüldü, tahmin değil:
8271 baytın 2963'ü, 308 CSI sekansı).

Bundan türetilen per-karakter maliyet:

| yol | ns/karakter |
|---|---|
| toplu ASCII (`printableTextRunLength` → `writeText`) | **2.2** |
| CSI içi (`ByteConsumer.consume()` başına) | **~23** |

*Türetme: ascii parser 431 MiB/s → 2.21 ns/char. sgr parser 99 MiB/s →
10.10 ms/MiB; bunun 673k metin karakteri toplu yoldan 1.49 ms, kalan 8.61 ms
375k CSI karakterine düşüyor → 22.9 ns/char.*

**Neden:** `ByteConsumer.consume()` her karakterde `_advancePastConsumedBlocks()`
+ `_decodeCodePoint` + `_codePointCodeUnitLength` + dört alan güncellemesi yapıyor.
Bu iş surrogate ve çok-kod-birimli karakterler için var. CSI parametrelerinde ise
yalnızca ASCII rakam, `;` ve `:` bulunur — o işin tamamı boşa gidiyor.

Metin yolunda bu zaten çözülmüş durumda:

```dart
// lib/src/utils/byte_consumer.dart
int get printableTextRunLength { ... }      // blok içinde toplu tara
void consumeAsciiCodeUnits(int count) { ... } // toplu ilerlet
```

`consumeAsciiCodeUnits` `_rollbackAvailable`'ı doğru tutuyor, yani mekanizma
rollback açısından güvenli. **CSI parametre taraması bu çiftin ikizinden yoksun.**

Bu bir aday, kabul edilmiş çözüm değil.

---

## 7. Denenip REDDEDİLEN — tekrarlanmasın

**Fikir:** Scroll'da her satır, öne düşen bir satırı tahliye edip arkaya aynı boyda
yenisini allocate ediyor (`buffer.dart` `_newEmptyLine`). Geniş grid'de her biri
birkaç KiB'lık `Uint32List`. Tahliye edilen depolamayı geri vermek steady state'i
allocation'sız yapmalı. `IndexAwareCircularBuffer`'da `onEvict` hook'u bu iş için
zaten duruyor.

**Uygulama:** `Buffer`'da serbest liste (derinlik 64), `onEvict`'ten besleniyor,
`_newEmptyLine` aynı genişlikte satır varsa oradan alıyor; `resetForReuse()`
`_data`'yı `fillRange` ile sıfırlıyor. Anchor taşıyan satırlar havuza alınmıyor.

**Sonuç: ~2 kat yavaş.** Temizlemeyi geçici olarak çıkararak (o hâliyle yanlış,
sadece ölçüm için) maliyet ayrıştırıldı:

| workload | taban | havuz + `fillRange` | havuz, temizlemesiz |
|---|---|---|---|
| ascii | 102 | 52 | **147** |
| ascii-long-lines | 153 | 77 | **209** |
| sgr | 76 | 57 | 82 |
| utf8 | 59 | 32 | **84** |
| cyrillic | 83 | 42 | **131** |
| altscreen | 170 | 174 | 174 |

**Yani havuzlama fikri doğru, temizleme onu öldürüyor.** Geri dönüşümün kendisi
scroll ağırlıklı yüklerde %37–58 kazandırıyor.

**Kök neden:** Dart'ta taze bir `Uint32List` allocate etmek, mevcut birini
temizlemekten ucuz. VM taze tipli veriyi işletim sisteminin zaten sıfırladığı
sayfalardan veriyor, yani allocation'daki sıfırlama pratikte bedava; `fillRange`
ise soğuk ve halihazırda fault'lanmış birkaç KiB'ı gerçekten yazıyor. İki yol da
"aynı kadar sıfırlıyor", maliyetleri aynı değil.

**Bir daha denenirse** tam temizlemeden kaçınmak şart — örneğin satır başına
"yazılmış en yüksek sütun" işareti tutup yalnızca o aralığı temizlemek. Tipik kısa
shell satırlarında öder, tam genişlik çıktıda ödemez.

Kod `master`'a girmedi, branch silindi.

**Yan tuzak:** `BufferLine.anchors` her çağrıda `UnmodifiableListView` allocate
ediyor. Bu deneyde suçlu değildi (kaldırmak 51 → 52 oynattı, gürültü) ama sıcak
bir yolda allocation yapmayan bir `hasAnchors` gerekir.

---

## 8. Kısıtlar

- **Ölçmeden birleştirme yok.** Bu reponun kuralı: Faz 1, 3 ve 5 böyle reddedildi.
  Her değişiklik `parse_bench` ile ölçülüp önce/sonra tablosuyla gelmeli. Negatif
  çıkarsa geri alınıp `RENDER_PLAN.md`'ye kayıt düşülmeli — reddedilen deneyin
  kaydı da bir çıktıdır.
- CSI döngüsünde hassas durum var: `rawLength` / `_maxCsiRawLength` taşma
  kontrolü, yarım kalan sekansta rollback, `_csiOverflowed`. Toplu bir yol
  bunların hepsini birebir korumalı. CSI'ın blok sınırına bölündüğü ve taşma
  sınırına dayandığı vakalar için yeni test şart.
- `dart analyze` sıfır uyarı, `flutter test` tamamen yeşil olmalı.
  Bu brifing yazılırken `master` @ `1537440` üzerinde taban **853 test geçiyor,
  1 atlanıyor** — bir değişiklik bu sayıyı düşürmemeli.
- Ölçüm gürültü bandı, Faz 2'de dört koşuyla belirlendi: **±0.5 ms** (frame
  ölçümleri için). `parse_bench` throughput sayıları daha kararlı ama tek koşuya
  güvenilmemeli.

---

## 9. Açık soru

`Terminal.write`'ı, özellikle SGR ağırlıklı çıktıda, nasıl hızlandırırız?

Bilinen üç açık cephe, hepsi ölçülmüş, hiçbiri çözülmemiş:

1. **CSI parametre tarama maliyeti** — karakter başına ~23 ns, toplu metin
   yolunun 10 katı. Bölüm 6.
2. **Buffer yazım yolu** — düz metinde toplam sürenin %76–81'i. Bölüm 5.
   Havuzlama denendi ve reddedildi (bölüm 7); başka yaklaşımlar açık.
3. **Scrollback tutma maliyeti** — %46–70. Bölüm 5. Bunun ne kadarının GC
   promotion baskısı, ne kadarının başka bir şey olduğu ölçülmedi.

`BENCHMARKS.md`'de ayrıca iki açık ölçüm borcu var: `sgr` workload'ının viewport'u
takip edip etmediği, ve `fullscreen`'in koşular arası tek yönlü tırmanışının
termal sürüklenme mi gerçek bir regresyon mu olduğu.
