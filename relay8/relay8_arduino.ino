/*
 * 5V 8-Kanal USB Röle Kartı — Arduino Sürücüsü
 * --------------------------------------------------
 * Bağlantı:
 *   Röle kartının IN1..IN8 pinleri -> Arduino D2..D9
 *   Röle kartı GND -> Arduino GND  (ORTAK GND ZORUNLU!)
 *   Röle kartı 5V  -> USB veya harici 5V adaptör
 *
 * ÇALIŞMA MANTIĞI (bu modüllerde standart):
 *   digitalWrite(pin, LOW)  -> Röle AÇIK  (LED yanar)
 *   digitalWrite(pin, HIGH) -> Röle KAPALI (LED söner)
 *
 * Seri monitörden (baud 9600) komutlar:
 *   1        -> 1. röleyi AÇ
 *   0        -> 1. röleyi KAPAT
 *   1-3      -> 1,2,3 numaralı röleleri AÇ
 *   0-2      -> 1,2,3 numaralı röleleri KAPAT
 *   allon    -> Hepsini AÇ
 *   alloff   -> Hepsini KAPAT
 *   toggle 4 -> 4. röleyi ters çevir (aç->kapalı, kapalı->açık)
 *   status   -> Mevcut durumu yazdır
 */

const int NUM_RELAYS = 8;
const int relayPins[NUM_RELAYS] = {2, 3, 4, 5, 6, 7, 8, 9}; // IN1..IN8

// TRUE = röle AÇIK. Dikkat: pin LOW olduğunda röle açılır (bkz. yukarı).
bool relayState[NUM_RELAYS] = {false};

// Eğer kartın üzerindeki röleler TERS çalışıyorsa (HIGH ile açılıyorsa)
// bu değeri 1 yap. Çoğu 5V 8-kanal kart 0 (LOW = aktif) kullanır.
const int ACTIVE_LOW = 1;

void setup() {
  Serial.begin(9600);
  for (int i = 0; i < NUM_RELAYS; i++) {
    pinMode(relayPins[i], OUTPUT);
    setRelay(i, false); // başlangıçta hepsi kapalı
  }
  Serial.println("8-Kanal Röle Kartı hazir. Komutlar: 1..8, allon, alloff, toggle N, status");
}

void loop() {
  if (Serial.available() > 0) {
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    if (cmd.length() == 0) return;

    // Sayısal komut: "1", "0", "1-3", "0-2"
    if (cmd.indexOf('-') >= 0) {
      int dash = cmd.indexOf('-');
      char c0 = cmd.charAt(0);
      int onOff = (c0 == '1') ? 1 : 0;
      int from = cmd.substring(0, dash).toInt();
      int to   = cmd.substring(dash + 1).toInt();
      if (from >= 1 && to <= NUM_RELAYS && from <= to) {
        for (int ch = from; ch <= to; ch++) setRelay(ch - 1, onOff == 1);
        printStatus();
      } else {
        Serial.println("Hatali aralik. Ornek: 1-3 (ac), 0-2 (kapat)");
      }
    }
    else if (cmd == "allon")  { for (int i = 0; i < NUM_RELAYS; i++) setRelay(i, true);  printStatus(); }
    else if (cmd == "alloff") { for (int i = 0; i < NUM_RELAYS; i++) setRelay(i, false); printStatus(); }
    else if (cmd.startsWith("toggle ")) {
      int ch = cmd.substring(7).toInt() - 1;
      if (ch >= 0 && ch < NUM_RELAYS) { setRelay(ch, !relayState[ch]); printStatus(); }
    }
    else if (cmd == "status") { printStatus(); }
    else {
      int ch = cmd.toInt() - 1;
      if (ch >= 0 && ch < NUM_RELAYS) {
        // "1" = ac, "0" = kapat; tek basina sayi verildiginde acik olarak yorumla
        bool on = (cmd.charAt(0) == '0') ? false : true;
        setRelay(ch, on);
        printStatus();
      } else {
        Serial.println("Bilinmeyen komut.");
      }
    }
  }
}

void setRelay(int idx, bool on) {
  relayState[idx] = on;
  int level = on ? LOW : HIGH;          // LOW = acik
  if (ACTIVE_LOW == 0) level = on ? HIGH : LOW; // ters mantik
  digitalWrite(relayPins[idx], level);
}

void printStatus() {
  for (int i = 0; i < NUM_RELAYS; i++) {
    Serial.print("R");
    Serial.print(i + 1);
    Serial.print(": ");
    Serial.println(relayState[i] ? "ACIK" : "kapali");
  }
  Serial.println("---");
}
