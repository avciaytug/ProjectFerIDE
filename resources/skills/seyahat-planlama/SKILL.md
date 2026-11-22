---
name: seyahat-planlama
description: "Tatil ve seyahat planı: uçuş, konaklama ve ulaşım karşılaştırma, gün gün plan ve bütçe, vize gereklilikleri ve evrak listesi, takvime ekleme. Kullanıcı bir gezi, tatil, iş seyahati ya da vize işi istediğinde yükle."
---

# Seyahat planlama

Tarayıcı kullanacağın için önce `tarayici-ile-calisma` skill'ini de yükle.

## 1. Bilgileri topla (eksikse tek mesajda kısaca sor)
- Nereden, nereye (ya da "öneri istiyorum"), tarihler (esnek mi?), kaç kişi (yetişkin / çocuk)
- Bütçe (kişi başı ya da toplam), konaklama tercihi (otel / daire, konum, puan)
- Uyruk ve pasaport (vize için gerekli), varsa geçerli vize ya da oturum izni
- Özel istekler: aktarmasız uçuş, bagaj, kahvaltı, erişilebilirlik, çocukla seyahat

Hafızadaki tercihlere `recall` ile bak; yeni öğrendiğin kalıcı tercihleri (ör. "hep koridor koltuğu") `remember` ile kaydet.

## 2. Araştır
- **Uçuş:** Google Uçuşlar (https://www.google.com/travel/flights) ile tarihlere göre karşılaştır. En ucuz, en kısa ve
  aktarmasız seçenekleri not et: havayolu, saatler, aktarma, bagaj hakkı, fiyat. Gerekirse havayolunun kendi sitesine bak.
- **Konaklama:** Google Oteller ya da Booking.com. Konum, puan, vergiler dahil toplam fiyat ve iptal koşulunu not et.
- **Ulaşım:** havalimanı ile otel arası transfer, toplu taşıma kartları, şehirlerarası tren ya da otobüs.
- **Vize:** yalnızca resmi kaynaklar: hedef ülkenin büyükelçiliği / konsolosluğu, resmi vize portalı ya da yetkili aracı
  kurum (ör. VFS Global, iDATA, TLScontact). Bak: vize gerekiyor mu, türü, gerekli belgeler, ücret, randevu durumu,
  başvuru süresi. Pasaportun geçerlilik süresini hatırlat (çoğu ülke dönüşten sonra en az 3-6 ay ister).
- Her fiyat ve kural için kaynağın adresini ve baktığın tarihi yaz.

## 3. Planı hazırla
Kullanıcı başka bir yer istemedikçe çalışma alanına bir Markdown dosyası olarak yaz (ör. `seyahat-roma-2026.md`):
- **Özet:** tarihler, kişi sayısı, toplam tahmini bütçe
- **Ulaşım:** seçenek tablosu (fiyat, süre, aktarma, bağlantı) ve önerin, nedeniyle
- **Konaklama:** 2-3 seçenekli tablo ve önerin
- **Gün gün plan:** sabah / öğle / akşam; yürüme ve ulaşım süreleri gerçekçi olsun
- **Bütçe:** uçuş, konaklama, ulaşım, yemek, giriş ücretleri, vize, seyahat sigortası
- **Vize ve evrak listesi:** işaretlenebilir liste (☐) ve son başvuru tarihi
- **Yapılacaklar:** rezervasyon sırası ve son tarihler

## 4. Kullanıcının onayıyla yapılacaklar
- **Takvim:** uçuş saatlerini ve rezervasyonları Google Takvim'e ekleyebilirsin; kaydetme kullanıcı onayına gider.
- **Rezervasyon / satın alma:** ödeme sayfasına kadar ilerle, bilgileri özetle; ödemeyi ve son onayı kullanıcı yapar
  (wait_for_user). Kart bilgisi yazma.
- **Vize formu:** kullanıcının verdiği bilgilerle doldur. Belge yükleme, imza, CAPTCHA ve son gönderimi kullanıcı yapar.
- **Gmail:** "rezervasyon", "PNR", "booking confirmation" gibi aramalarla mevcut rezervasyonları bulup plana ekleyebilirsin.
  E-posta göndermeden önce taslağı kullanıcıya göster.
