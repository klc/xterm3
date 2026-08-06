# Flood benchmark — macOS, profile mode

**Tarih:** 2026-08-03 · **Branch:** `chore/verified-review-fixes` · **Platform:** macOS
**Mod:** `profile` (doğrulandı: `release mode: false, profile mode: true`)
**Grid:** 100×37 = 3700 hücre, viewport 1000×600 logical px
**Araç:** `example/lib/benchmark.dart`

Bu ölçüm `CODE_REVIEW_VERIFIED.md` §3.1 ve §3.2'nin ("ölçmeden optimize etme") karar
girdisidir. Debug modu sayıları yanıltıcıdır ve daha önce yanlış yola sokmuştur —
bu koşu profile modunda yapılmıştır.

## Sonuçlar

Frame bütçesi 60fps'te **16.7 ms**.

| workload | frame | UI p50 | p90 | p99 | RASTER p50 | p90 | p99 | bütçe aşımı |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| plain | 408 | 1.4 | 1.6 | 2.2 | 2.2 | 2.6 | 3.4 | **0.0%** |
| sgr | 408 | 1.8 | 2.2 | 3.9 | 2.2 | 2.6 | 3.1 | **0.0%** |
| boxdraw | 415 | 2.3 | 2.5 | 2.8 | 3.2 | 3.4 | 3.6 | **0.0%** |
| fullscreen | 408 | 2.0 | 3.6 | 5.4 | 2.0 | 2.7 | 3.7 | **0.0%** |

**Flood (`cat bigfile` senaryosu):**
- 32.2 MiB / 440 ms → **75.0 MiB/s** parse throughput
- burst sırasında **21 frame** render edildi → **47.7 fps**
- **en kötü UI frame: 4.2 ms** (burst + flush dahil)

## Yorum

**Normal workload'larda hiçbir frame bütçeyi aşmıyor.** En kötü p99 (fullscreen, 5.4 ms)
bütçenin ~%32'si; tipik p50 değerleri %8–14 bandında. 3700 hücrenin tamamı her frame
yeniden çiziliyor ve raster maliyeti p99'da 3.7 ms — yani tam viewport repaint bu grid
boyutunda ucuz.

**Flood senaryosunda kritik sayı fps değil, en kötü UI frame süresi: 4.2 ms.**
Parse UI thread'ini bloke ediyor olsaydı tek tek frame'lerin 16.7 ms'i çok aşması
gerekirdi. Aşmıyor. 60 yerine 47.7 fps çıkmasının sebebi frame'lerin *yavaş* olması
değil, event loop'ta 4096 chunk işlenirken frame'lerin daha seyrek *zamanlanması*.
Kullanıcıya jank/stutter olarak değil, hafif düşük frame oranı olarak yansır.

## Kararlar

`CODE_REVIEW_VERIFIED.md`'de belirlenen kural: parse payı frame bütçesinin %30'unu
geçmiyorsa #15 ve #16 düşük öncelik.

- **#16 dirty-row tracking → GEREKSİZ.** Tam viewport repaint p99'da 3.7 ms raster.
  Kirletme takibi hot write path'e maliyet ekler ve kirletme noktalarından birini
  kaçırmak görsel bug üretir. Ölçülebilir bir kazanç karşılığı değil.
- **#15 frame-coalescing → GEREKÇESİZ.** Kazanç flood sırasında ~12 fps; jank yok,
  en kötü frame 4.2 ms. Senkron cevap protokollerini (DA, DSR, DECRQM) geciktirme
  riski taşıyor. Kazanç riski karşılamıyor.

Her iki kaynak inceleme raporunun "sürekli çıktı UI'ı aç bırakıyor" / "`cat 50MB.txt`
Flutter render'ını dondurur" iddiası **bu ölçümle çürüdü**: 32 MiB flood sırasında en
kötü UI frame 4.2 ms. Aynı şekilde parser'ı Isolate'e taşıma önerisinin de dayanağı yok.

## Sınır

Bu ölçüm **macOS masaüstünde**. xterm3'nin ayırt edici özelliği mobil destek ve mobil
donanım belirgin şekilde yavaş. #15/#16 kesin olarak kapatılmadan önce gerçek bir
Android/iOS cihazda aynı benchmark çalıştırılmalı. Masaüstü için karar nettir.
