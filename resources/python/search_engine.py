import sys
import json

try:
    from ddgs import DDGS
except ImportError:
    try:
        from duckduckgo_search import DDGS
    except ImportError:
        print(json.dumps([{"error": "'ddgs' veya 'duckduckgo_search' bulunamadı. Lütfen 'pip install ddgs' çalıştırın."}]))
        sys.exit(0)

def search_web(query, max_results=5):
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=max_results))
            print(json.dumps(results))
    except Exception as e:
        print(json.dumps([{"error": f"Arama hatası: {str(e)}"}]))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps([{"error": "Lütfen bir arama terimi girin."}]))
        sys.exit(0)
        
    query = sys.argv[1]
    max_res = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    search_web(query, max_res)
