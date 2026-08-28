# xterm3 — Write path throughput brifingi

**Tarih:** 2026-08-29 · **Taban:** `master` @ `1537440` (release 6.1.3)
**Revizyon:** 2026-08-29 — bölüm 5'in `parser` kolonu bozuk çıktı ve yeniden
ölçüldü; bölüm 5, 6, 7 ve 9 buna göre güncellendi (Faz 5.1)
**Amaç:** `Terminal.write` yolunun neden yavaş kaldığını, nelerin ölçüldüğünü ve
nelerin denenip reddedildiğini tek dosyada devretmek.

Bu dosya bir çözüm önerisi değil, bir problem tanımı. Bölüm 9'daki üç aday
tavanlarına göre sıralı, ama hiçbiri uygulanmadı; ilk yazımda tek aday olarak
sunulan CSI toplu tarama, düzeltilmiş ölçümden sonra üçüncü sıraya düştü.

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

## 3. Render tekil frame bütçesini zorlamıyor — `drawAtlas` sorusu kapandı

Faz 0–4 bunu ölçtü. Dikkat: kapanan soru `drawAtlas`'a geçmekti, render'ın
tümü değil. Flood altında sürdürülebilir frame hızını hâlâ raster belirliyor
(aşağıdaki Faz 3 maddesi bunu söylüyor) — o ayrı bir cephe, bu brifingin
konusu değil ama "render kapalı dosya" diye okunmamalı.

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
  (`bin/noop_escape_handler.dart`, 233 üyenin hepsi açıkça uygulanmış;
  `noSuchMethod` **eklenmemeli**, sebebi o dosyanın başlığında)
- `buffer%` — tam yol süresinin parse olmayan kısmı
- `scrollback` — `maxLines: 0` ile `Terminal.write`
- `no-grapheme` — DEC mode 2027 kapalı

---

## 5. Taban ölçüm

M-serisi macOS, MiB/s, üçer koşunun medyanı.

| workload | full | parser | buffer% | scrollback kapalı | grapheme kapalı |
|---|---|---|---|---|---|
| ascii | 105 | 568 | 82% | 171 | 107 |
| ascii-long-lines | 151 | 910 | 84% | 227 | 149 |
| **sgr** | **77** | **121** | **36%** | 88 | 77 |
| utf8 | 59 | 333 | 82% | 86 | 69 |
| cyrillic | 85 | 360 | 76% | 139 | 86 |
| altscreen | 170 | 279 | 39% | 175 | 175 |

Bu tablo, ilk yazımdakinin yerini alıyor. Eskisinin `parser` ve `buffer%`
kolonları bir harness kusurundan geliyordu: bench'in no-op handler'ı
`EscapeHandler`'ın 233 üyesini `noSuchMethod`'a düşürüyor, her çağrıda bir
`Invocation` allocate ediyordu. Ölçülen artefakt: argümansız çağrıda 22–24 ns,
argümanlıda 37–44 ns; `ascii`'de MiB başına ~22.000, `sgr`'de ~50.000 çağrı.
`full`, `scrollback` ve `grapheme kapalı` kolonları etkilenmemişti ve
düzeltmeden sonra da kıpırdamadılar. Tam kayıt: `RENDER_PLAN.md`, Faz 5.1.

### Üç okuma

1. **Escape parser çoğu yükte darboğaz değil.** `ascii`'de parser tek başına
   568 MiB/s, tam yol 105. Zamanın **%82–84'ü** buffer yazımında. "Parser yavaş"
   teşhisi bu yükler için yanlış olur — ve düzeltilmiş sayılarla daha da yanlış.
2. **SGR istisna, ama sanıldığı kadar değil.** Orada buffer %36 — kalan %64
   parser'ın kendisi, ve 121 MiB/s ile açık ara en yavaş parse yolu (sonraki en
   yavaş: altscreen 279). Gerçek CLI çıktısı (renkli prompt, `ls --color`, build
   log'ları, `htop`) SGR ağırlıklı olduğu için pratikte en çok ödenen yol budur.
   İlk yazımdaki "%23 buffer / %77 parser" rakamı artefaktın kendisiydi.
3. **Scrollback tutmak pahalı.** Kapatınca ascii 105 → 171 (+%63), cyrillic
   85 → 139 (+%64), utf8 59 → 86 (+%46). Bu okuma kusurdan etkilenmedi.

---

## 6. Bulunan somut nokta — üst sınır ölçüldü, payı hâlâ bilinmiyor

`sgr` payload'ının **%35.8'i** CSI baytı (sayılarak ölçüldü, tahmin değil:
8271 baytın 2963'ü, 308 CSI sekansı).

Bundan türetilen per-karakter maliyet:

| yol | ns/karakter |
|---|---|
| toplu ASCII (`printableTextRunLength` → `writeText`) | **1.7** |
| CSI içi, karakter başına **üst sınır** | **~19** |

*Türetme: ascii parser 568 MiB/s → 1.72 ns/char. sgr parser 121 MiB/s →
8.26 ms/MiB; bunun 673k metin karakteri toplu yoldan 1.16 ms, kalan 7.11 ms
375k CSI karakterine düşüyor → 18.9 ns/char.*

**Bu bir üst sınır, `consume()`'un payı değil.** O 7.11 ms'in içinde `consume()`
dışında şunlar da var: sekans başına `_csi.params.clear()` +
`intermediates.clear()` + `paramSeparators.clear()`, parametre başına growable
`add()`, `FastLookupTable` dispatch'i ve `_csiHandleSgr`'ın parametre yürüyüşü.
Hepsi MiB başına ~39.000 sekans üzerinden ödeniyor. `consume()`'un gerçek payı
ölçülmedi; ölçmeden CSI toplu tarayıcısı yazmak, kazancı bilinmeyen bir işe
en riskli invariantları (aşağıdaki bölüm 8) sokmak olur.

Ölçmenin ucuz yolu bölüm 7'de zaten kullanılmış: CSI döngüsündeki `consume()`'u
geçici olarak çıplak `codeUnitAt` + `offset++` ile değiştir (o hâliyle yanlış,
sadece ölçüm için) ve tavanı gör.

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

**Kök neden — HİPOTEZ, doğrulanmadı.** İlk yazım şöyle diyordu: VM taze tipli
veriyi işletim sisteminin zaten sıfırladığı sayfalardan verir, yani
allocation'daki sıfırlama bedavadır. Bu 170 sütunluk bir satır için muhtemelen
yanlış — o 680 baytlık bir `Uint32List`, yani new-space bump-pointer
allocation'ı, ve Dart onu açıkça sıfırlıyor. Daha olası iki aday: **önbellek
konumu** (taze satır sıcak TLAB belleğine düşüyor, havuzdan gelen satır uzun süre
önce tahliye edilmiş ve soğuk) ve `Uint32List.fillRange`'in AOT'ta memset'e
intrinsify edilip edilmediği.

Ayrım pratik: OS-sayfası modeli doğruysa kısmi temizleme de kaybeder; önbellek
modeli doğruysa kazanır, çünkü kısa shell satırlarında dokunulan aralık bir cache
line'a sığar. Ölçülen (2 kat yavaşlama) sağlam, açıklama değil.

**Bu deneyin ölçmeden cevapladığı bir soru var.** Kendi iki tablosunu yan yana
koy: scrollback cezasının ne kadarını havuzlama geri alıyor?

| workload | taban | scrollback kapalı | havuz, temizlemesiz | ceza | geri alınan |
|---|---|---|---|---|---|
| ascii | 102 | 173 | 147 | 71 | 45 (%63) |
| cyrillic | 83 | 140 | 131 | 57 | 48 (%84) |
| utf8 | 59 | 86 | 84 | 27 | 25 (%93) |

Yani scrollback tutmanın maliyetinin %63–93'ü satır allocation'ı. Bölüm 9'un
3. açık sorusu ("ne kadarı GC promotion baskısı") büyük ölçüde cevaplı.

**Bir daha denenirse** tam temizlemeden kaçınmak şart — örneğin satır başına
"yazılmış en yüksek sütun" işareti tutup yalnızca o aralığı temizlemek. Tipik kısa
shell satırlarında öder, tam genişlik çıktıda ödemez.

Kod `master`'a girmedi, branch silindi.

**Yan tuzak:** `BufferLine.anchors` her çağrıda `UnmodifiableListView` allocate
ediyor. Bu deneyde suçlu değildi (kaldırmak 51 → 52 oynattı, gürültü) ama sıcak
bir yolda allocation yapmayan bir `hasAnchors` gerekir.

---

## 8. Kısıtlar

- **Harness'ı önce doğrula.** Faz 5.1'in dersi: brifingin iki teşhisi de bir
  ölçüm artefaktından çıkmıştı. `bin/noop_escape_handler.dart`'a `noSuchMethod`
  eklemek (ya da `EscapeHandler`'a üye ekleyip dosyayı yeniden üretmemek)
  `parser` kolonunu tekrar zehirler. Dosya `script/gen_noop_handler.dart` ile
  üretiliyor, elle yamanmıyor.
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
  1 atlanıyor** — bir değişiklik bu sayıyı düşürmemeli. Faz 5.1 sonrası aynı.
- Ölçüm gürültü bandı, Faz 2'de dört koşuyla belirlendi: **±0.5 ms** (frame
  ölçümleri için). `parse_bench` throughput sayıları daha kararlı ama tek koşuya
  güvenilmemeli.

---

## 9. Açık soru

`Terminal.write`'ı, özellikle SGR ağırlıklı çıktıda, nasıl hızlandırırız?

Düzeltilmiş tabandan çıkan sıra — en yüksek ölçülmüş tavandan en düşüğe:

1. **Satır havuzu, 2. deneme (sınırlı temizleme).** Tavanı zaten ölçülü:
   bölüm 7'nin "havuz, temizlemesiz" kolonu, ascii 102 → 147. Fikir doğru,
   temizleme stratejisi yanlıştı. Ama önce bölüm 7'deki kök neden ayrımı
   ölçülmeli, çünkü kısmi temizlemenin ödeyip ödemeyeceği ona bağlı.
2. **`ByteConsumer.consume()` ASCII fast path.** `byte_consumer.dart:31-42`:
   `_decodeCodePoint` ve `_codePointCodeUnitLength` aynı surrogate testini iki
   kez yapıyor, `first < 0xd800` iken ikisinin de cevabı sabit. ~10 satır, yeni
   durum yok, rollback semantiği değişmiyor (`_previousRuneOffset` surrogate
   olmayan için zaten `offset - 1` veriyor). `consume()` çağıran her yol
   kazanıyor — sgr, utf8, altscreen, OSC, `_discardCsiInput`. Aynı zamanda
   madde 3'ün ön elemesi.
3. **CSI parametre tarama maliyeti.** Karakter başına **en fazla** ~19 ns.
   Bölüm 6 — ve orada yazdığı gibi, bu üst sınırın ne kadarının `consume()`
   olduğu ölçülmeden yazılmamalı.

Bu üçünün toplamı bile saha semptomunu kapatmaz. Bunun sebebi bölüm 1'de duruyor
ama sonucu orada yazılmamış: vtebench 40–90 MiB/s süregelen üretiyor, write sgr'de
77 MiB/s, ve kuyruk sınırsız. Write'ı %30 hızlandırmak donmayı gidermez,
geciktirir. xterm3 içinde kalan asıl kaldıraç, backlog bir eşiği aştığında
scrollback'e yazmayı / reflow'u / anchor bakımını atlayan bir mod; tavanı
`scrollback kapalı` kolonunda zaten duruyor (ascii +%63). `RENDER_PLAN.md`'de
Faz 6 adayı olarak kayıtlı, bilerek bu round'un dışında.

Not: bölüm 1'in "uygulama tarafında düzeltilemez" tespiti `flutter_pty`'nin
**public Stream API'si** için doğru; native okuma tarafının fork'lanamayacağı
ya da fd'nin bir isolate'ten okunamayacağı anlamına gelmiyor. O kapı kapalı
ilan edildi ama denenmedi.

`BENCHMARKS.md`'de ayrıca iki açık ölçüm borcu var: `sgr` workload'ının viewport'u
takip edip etmediği, ve `fullscreen`'in koşular arası tek yönlü tırmanışının
termal sürüklenme mi gerçek bir regresyon mu olduğu.
