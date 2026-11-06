import sys
import json
import urllib.request
import urllib.error

def get_crypto_price(symbol):
    # Binance API
    if not symbol.endswith("USDT"):
        symbol = symbol + "USDT"
    
    url = f"https://api.binance.com/api/v3/ticker/24hr?symbol={symbol.upper()}"
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode())
            return {
                "symbol": data.get("symbol"),
                "current_price": float(data.get("lastPrice", 0)),
                "price_change_percent": float(data.get("priceChangePercent", 0)),
                "volume": float(data.get("volume", 0)),
                "high_24h": float(data.get("highPrice", 0)),
                "low_24h": float(data.get("lowPrice", 0))
            }
    except urllib.error.HTTPError as e:
        return {"error": f"Binance API hatası ({e.code}): Sembol bulunamadı veya geçersiz."}
    except Exception as e:
        return {"error": f"Kripto veri çekme hatası: {str(e)}"}

def get_stock_price(symbol):
    # yfinance kütüphanesini dinamik olarak içe aktarmayı dene
    try:
        import yfinance as yf
    except ImportError:
        return {"error": "'yfinance' kütüphanesi eksik. Lütfen 'pip install yfinance' çalıştırın."}
    
    try:
        ticker = yf.Ticker(symbol.upper())
        info = ticker.info
        
        # Yahoo Finance API yapısı zaman zaman değişebilir
        current_price = info.get("currentPrice") or info.get("regularMarketPrice") or info.get("previousClose")
        if not current_price:
            return {"error": f"{symbol} için fiyat verisi bulunamadı."}
            
        return {
            "symbol": symbol.upper(),
            "name": info.get("shortName", symbol.upper()),
            "current_price": current_price,
            "currency": info.get("currency", "USD"),
            "sector": info.get("sector", "N/A"),
            "market_cap": info.get("marketCap", "N/A"),
            "fifty_two_week_high": info.get("fiftyTwoWeekHigh", "N/A"),
            "fifty_two_week_low": info.get("fiftyTwoWeekLow", "N/A")
        }
    except Exception as e:
        return {"error": f"Hisse senedi veri çekme hatası: {str(e)}"}

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps([{"error": "Kullanım: python3 finance_engine.py [crypto|stock] [SEMBOL]"}]))
        sys.exit(0)
        
    asset_type = sys.argv[1].lower()
    symbol = sys.argv[2].upper()
    
    result = None
    if asset_type == "crypto":
        result = get_crypto_price(symbol)
    elif asset_type == "stock":
        result = get_stock_price(symbol)
    else:
        result = {"error": "Geçersiz varlık tipi. 'crypto' veya 'stock' kullanın."}
        
    print(json.dumps([result] if result else []))
