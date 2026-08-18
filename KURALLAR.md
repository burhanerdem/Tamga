# TAMGA — Oyun Kuralları

Tamga, 20x20'lik bir tahtada oynanan, iki kişilik derin bir strateji ve alan kontrolü oyunudur.

Oyunda amaç rakip taşları doğrudan yemek değil; tahtadaki etki alanınızı kullanarak rakibi kendi taşlarının yanına hamle yapmaya mecbur bırakmak ve taşlarını **"Tamgalayarak"** (mühürleyerek) puan toplamaktır.

---

## 🎯 Oyunun Amacı

Oyun bittiğinde tahtada tamgalanmış taşı daha fazla olan oyuncu kazanır. (Tamgalı taş sayıları eşitse, tahtadaki toplam taş sayısına bakılır).

---

## 🔴🔵 Hamleler ve Sıra

- **Oyuncu 1:** Kırmızı Taşlar
- **Oyuncu 2:** Mavi Taşlar

Sırası gelen oyuncu aşağıdaki iki hamleden birini yapmak zorundadır. Pas geçmek yasaktır. Hamle yapıldıktan sonra sıra rakibe geçer.

1. **Taş Koymak (Sol Tık):** Tahtadaki boş ve kilitli olmayan bir kareye kendi taşını koyar.
2. **Taş Geri Toplamak (Sağ Tık):** Kendisine ait, henüz tamgalanmamış bir taşı tahtadan geri alır. *(Bu hamle pas geçmek değildir; etki alanlarını değiştiren taktiksel bir hamledir).*

---

## 🔒 Etki Alanı ve Kilitleme Mekaniği

Bir taş tahtaya konduğunda, etrafındaki 8 komşu kareye kendi renginden bir "kısıtlama etkisi" yayar. Tahtadaki her boş karenin kilit durumu şu kurallara göre belirlenir:

1. **Etki Yok (0 Taş):** Kare serbesttir, her iki oyuncu da taş koyabilir.
2. **Kilitli (1 Taş):** Bir karenin etrafında aynı renkten tam olarak 1 adet taş varsa, o kare o renk tarafından kilitlenir. Hiçbir oyuncu oraya taş koyamaz.
3. **Kilit Açılır (2+ Taş):** Aynı renkten ikinci (veya daha fazla) taş o kareyi etkilemeye başlarsa, kilit kalkar ve kare tekrar oynanabilir hale gelir.

> ⚠️ **Önemli Not:** Kırmızı ve Mavi kilitler birbirinden bağımsızdır. Kendi taşlarınızla bir karenin kilidini açmış (2+ etki) olsanız bile, rakibin o karede 1 birimlik (kilitleyici) etkisi varsa, o kareye taş koyamazsınız.

---

## ⚜️ Tamgalama Mekaniği (Puan Kazanma)

Tamgalama, oyundaki yegane puan kazanma ve taşı kalıcı hale getirme yöntemidir:

- **Pasif Tamgalama (Rakip Tarafından):** Siz taşı koyduktan sonraki turlarda rakip gelip taşınızın bitişiğine (8 komşusuna) taş koyarsa, taşınız rakip etki alanına girdiği için Tamgalanır.
- **Aktif Tamgalama (Anında):** Eğer siz kendi isteğinizle, rakibin halihazırda var olan bir taşının yanına kendi taşınızı koyarsanız, koyduğunuz yeni taş anında Tamgalanır.

### Tamgalı Taşların Özellikleri:
- Üzerlerinde **altın renkli bir nokta** (Tamga) belirir.
- Tamgalanma kalıcıdır. Rakip kendi taşını oradan çekse bile tamga silinmez.
- Tamgalı bir taş, sahibi tarafından bir daha sağ tık ile tahtadan geri alınamaz.

---

## ⏳ Süper Ko Kuralı (Sonsuz Döngü Yasağı)

Oyun boyunca tahtada oluşmuş olan hiçbir taş dizilimi (pozisyon) bir daha asla tekrar edilemez. Eğer yapacağınız bir hamle (örneğin bir taşı geri çekmek), tahtayı oyunun geçmişindeki herhangi bir turla birebir aynı hale getiriyorsa, bu hamle kural dışı sayılır ve sistem tarafından reddedilir.

---

## 🏁 Oyunun Bitişi ve Kazanan

Sırası gelen oyuncunun yapabileceği hiçbir yasal hamle kalmadığında (boş yer yoksa, geri alınacak taşı kalmadıysa veya tüm hamleler Süper Ko kuralına takılıyorsa) oyun biter.

Oyun bittiğinde:
1. Daha çok **tamgalanmış (altın noktalı)** taşı olan oyuncu kazanır.
2. Tamgalı taş sayıları eşitse, tahtada **toplam daha fazla taşı** olan oyuncu kazanır.
3. İki durum da eşitse, sonuç **"Kusursuz Beraberlik"** olur.
