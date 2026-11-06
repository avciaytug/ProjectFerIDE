import sys
import json
try:
    import yfinance as yf
    import pandas as pd
except ImportError:
    print(json.dumps([{"error": "Lütfen gerekli kütüphaneleri yükleyin: pip install yfinance pandas"}]))
    sys.exit(0)

def calculate_rsi(data, window=14):
    delta = data['Close'].diff(1)
    gain = (delta.where(delta > 0, 0)).rolling(window=window).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=window).mean()
    rs = gain / loss
    rsi = 100 - (100 / (1 + rs))
    return rsi

def calculate_macd(data, short_window=12, long_window=26, signal_window=9):
    short_ema = data['Close'].ewm(span=short_window, adjust=False).mean()
    long_ema = data['Close'].ewm(span=long_window, adjust=False).mean()
    macd = short_ema - long_ema
    signal = macd.ewm(span=signal_window, adjust=False).mean()
    return macd, signal

def analyze_asset(symbol):
    try:
        # Son 3 aylık günlük veri çek
        ticker = yf.Ticker(symbol.upper())
        df = ticker.history(period="3mo", interval="1d")
        if df.empty:
            # Kripto sembolü yfinance'de genelde -USD son ekine sahiptir (Örn: BTC-USD)
            ticker = yf.Ticker(symbol.upper() + "-USD")
            df = ticker.history(period="3mo", interval="1d")
            
        if df.empty:
            return {"error": f"{symbol} için geçmiş veri bulunamadı. Lütfen sembolü kontrol edin."}
            
        df['RSI'] = calculate_rsi(df)
        df['MACD'], df['MACD_Signal'] = calculate_macd(df)
        
        last_row = df.iloc[-1]
        prev_row = df.iloc[-2]
        
        # Sinyal yorumlama
        rsi = last_row['RSI']
        macd = last_row['MACD']
        macd_signal = last_row['MACD_Signal']
        
        rsi_comment = "Nötr"
        if pd.isna(rsi):
            rsi_comment = "Hesaplanamadı"
        elif rsi > 70:
            rsi_comment = "Aşırı Alım (Satış Baskısı Gelebilir)"
        elif rsi < 30:
            rsi_comment = "Aşırı Satım (Alım Fırsatı Olabilir)"
            
        macd_comment = "Nötr"
        if pd.isna(macd) or pd.isna(macd_signal):
            macd_comment = "Hesaplanamadı"
        elif macd > macd_signal and prev_row['MACD'] <= prev_row['MACD_Signal']:
            macd_comment = "Al Sinyali (Kesişim)"
        elif macd < macd_signal and prev_row['MACD'] >= prev_row['MACD_Signal']:
            macd_comment = "Sat Sinyali (Kesişim)"
        elif macd > macd_signal:
            macd_comment = "Yükseliş Trendi"
        elif macd < macd_signal:
            macd_comment = "Düşüş Trendi"
            
        return {
            "symbol": symbol.upper(),
            "current_price": float(last_row['Close']),
            "RSI": float(rsi) if not pd.isna(rsi) else None,
            "RSI_Interpretation": rsi_comment,
            "MACD": float(macd) if not pd.isna(macd) else None,
            "MACD_Signal": float(macd_signal) if not pd.isna(macd_signal) else None,
            "MACD_Interpretation": macd_comment,
            "analysis_date": str(df.index[-1].date())
        }
    except Exception as e:
        return {"error": f"Analiz hatası: {str(e)}"}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps([{"error": "Kullanım: python3 finance_analyzer.py [SEMBOL]"}]))
        sys.exit(0)
        
    symbol = sys.argv[1]
    result = analyze_asset(symbol)
    print(json.dumps([result]))
