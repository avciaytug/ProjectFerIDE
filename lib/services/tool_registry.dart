/// FerIDE Modüler Araç Kaydı (Tool Registry - Claude Code Standartları)
///
/// Araç şemalarını kategorize ederek oturum tipine göre sadeleştirir.
/// Bu sayede prompt eval token yükünü ve gecikmesini minimize eder.
library;

class ToolRegistry {
  // 1. Core Araçlar (Dosya & Komut)
  static final Map<String, dynamic> runCommandTool = {
    "type": "function",
    "function": {
      "name": "run_command",
      "description":
          "Bilgisayarda bash/terminal komutu çalıştırır. Derleme, test, git, servis yönetimi gibi işlemler için kullanılır.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "Çalıştırılacak sistem komutu"
          },
          "background": {
            "type": "boolean",
            "description":
                "True ise komut arka planda ayrık (detached) başlatılır ve sistem bloke edilmez (GUI, tarayıcı veya arka plan servisleri için zorunludur)."
          }
        },
        "required": ["command"]
      }
    }
  };

  static final Map<String, dynamic> readFileTool = {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Lokal diskteki bir dosyanın içeriğini okur.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Dosyanın mutlak veya göreceli yolu"
          },
          "offset": {
            "type": "integer",
            "description": "Başlangıç satır numarası (0-indexed, varsayılan 0)"
          },
          "limit": {
            "type": "integer",
            "description": "Okunacak maksimum satır sayısı (varsayılan 500)"
          }
        },
        "required": ["path"]
      }
    }
  };

  static final Map<String, dynamic> writeToFileTool = {
    "type": "function",
    "function": {
      "name": "write_to_file",
      "description":
          "Yeni bir dosya oluşturur veya var olan dosyanın tamamını ezer.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Dosyanın yolu"},
          "content": {"type": "string", "description": "Yazılacak tam içerik"}
        },
        "required": ["path", "content"]
      }
    }
  };

  static final Map<String, dynamic> replaceFileContentTool = {
    "type": "function",
    "function": {
      "name": "replace_file_content",
      "description":
          "Dosya içindeki belirli bir bloğu yenisiyle değiştirir. Kesin eşleşme gerektirir.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Dosyanın yolu"},
          "target": {
            "type": "string",
            "description": "Değiştirilecek eski blok (Birebir eşleşmeli)"
          },
          "replacement": {
            "type": "string",
            "description": "Yeni blok"
          }
        },
        "required": ["path", "target", "replacement"]
      }
    }
  };

  // 2. Arama Araçları (Search & Discovery)
  static final Map<String, dynamic> grepSearchTool = {
    "type": "function",
    "function": {
      "name": "grep_search",
      "description":
          "Kod tabanında regex veya düz metin araması yapar. Hızlıca sembol, fonksiyon veya desen bulur.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": {"type": "string", "description": "Aranacak metin veya regex deseni"},
          "path": {
            "type": "string",
            "description": "Aramanın yapılacağı dizin veya dosya (varsayılan çalışma dizini)"
          },
          "case_insensitive": {
            "type": "boolean",
            "description": "Büyük/küçük harf duyarsız arama (varsayılan true)"
          }
        },
        "required": ["query"]
      }
    }
  };

  static final Map<String, dynamic> globTool = {
    "type": "function",
    "function": {
      "name": "glob",
      "description":
          "Dosya adlarına göre dosya listeler (Örn: **/*.dart, lib/**/*.json).",
      "parameters": {
        "type": "object",
        "properties": {
          "pattern": {
            "type": "string",
            "description": "Glob deseni (Örn: **/*.dart, src/**/*.ts)"
          },
          "path": {
            "type": "string",
            "description": "Kök arama dizini (varsayılan geçerli dizin)"
          }
        },
        "required": ["pattern"]
      }
    }
  };

  // 3. Evrensel Belge, Ofis, Medya ve AutoCAD Araçları
  static final Map<String, dynamic> readDocumentTool = {
    "type": "function",
    "function": {
      "name": "read_document",
      "description":
          "PDF (.pdf), Word (.docx, .doc, .odt), Excel (.xlsx, .xls, .ods, .csv), PowerPoint (.pptx, .ppt, .odp), Görsel/OCR (.png, .jpg, .webp, .tiff, .svg), Müzik/Ses (.mp3, .wav, .flac, .ogg, .m4a) ve AutoCAD (.dwg, .dxf) dosyalarını analiz eder ve yapılandırılmış metne dönüştürür.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Okunacak belgenin veya dosyanın mutlak/göreceli yolu"
          }
        },
        "required": ["path"]
      }
    }
  };

  static final Map<String, dynamic> editMediaOrDocumentTool = {
    "type": "function",
    "function": {
      "name": "edit_media_or_document",
      "description":
          "Word (.docx), Excel (.xlsx/.csv), PowerPoint (.pptx), PDF (.pdf), AutoCAD (.dwg/.dxf), Görsel (.png/.jpg/.webp) ve Müzik/Ses (.mp3/.wav/.flac) dosyaları oluşturur, düzenler veya dönüştürür.",
      "parameters": {
        "type": "object",
        "properties": {
          "category": {
            "type": "string",
            "enum": ["docx", "xlsx", "pptx", "pdf", "cad", "image", "audio"],
            "description": "Dosya kategorisi (cad = AutoCAD .dwg/.dxf)"
          },
          "action": {
            "type": "string",
            "description":
                "İşlem türü: create, edit, replace_text, update_cells, merge, extract_pages, rotate, stamp_text, convert, trim"
          },
          "input_path": {
            "type": "string",
            "description": "Düzenlenecek mevcut dosyanın yolu (yeni oluşturmada boş bırakılabilir)"
          },
          "output_path": {
            "type": "string",
            "description": "Kaydedilecek hedef dosya yolu (örn: rapor.docx, plan.dwg, sunum.pptx, tablo.xlsx, kesit.mp3)"
          },
          "title": {"type": "string", "description": "Belge/PDF başlığı veya ses parçası adı"},
          "paragraphs": {
            "type": "array",
            "items": {"type": "string"},
            "description": "Word veya PDF için paragraf listesi"
          },
          "sections": {
            "type": "array",
            "items": {"type": "object"},
            "description": "Word/PDF bölümleri: [{\"heading\":\"...\", \"paragraphs\":[...], \"bullets\":[...], \"table\":[[...]]}]"
          },
          "headers": {
            "type": "array",
            "items": {"type": "string"},
            "description": "Excel/CSV sütun başlıkları"
          },
          "rows": {
            "type": "array",
            "items": {"type": "array", "items": {}},
            "description": "Excel/CSV satır verileri: [[\"Ad\", 100], ...]"
          },
          "cells": {
            "type": "object",
            "description": "Excel hücre güncellemeleri: {\"B2\": 450, \"C2\": \"=SUM(A2:B2)\"}"
          },
          "slides": {
            "type": "array",
            "items": {"type": "object"},
            "description": "PowerPoint slaytları: [{\"title\":\"...\", \"subtitle\":\"...\", \"bullets\":[\"...\"]}]"
          },
          "replacements": {
            "type": "object",
            "description": "Word/PPTX metin değiştirme sözlüğü: {\"eski\": \"yeni\"}"
          },
          "operations": {
            "type": "array",
            "items": {"type": "object"},
            "description":
                "AutoCAD (.dwg/.dxf) çizim/düzenleme komutları: [{\"op\":\"add_rect\",\"layer\":\"DUVAR\",\"origin\":[0,0],\"width\":500,\"height\":400,\"label\":\"SALON\"}, {\"op\":\"add_line\",\"start\":[0,0],\"end\":[500,0]}, {\"op\":\"add_circle\",\"center\":[250,200],\"radius\":50}, {\"op\":\"add_text\",\"text\":\"KAT PLANI\",\"pos\":[20,20],\"height\":15}, {\"op\":\"replace_text\",\"find\":\"ESKI\",\"replace\":\"YENI\"}]"
          },
          "units": {
            "type": "string",
            "description": "AutoCAD çizim birimi: mm, cm, m, inch, ft"
          },
          "width": {"type": "integer", "description": "Görsel genişliği (px)"},
          "height": {"type": "integer", "description": "Görsel yüksekliği (px)"},
          "rotate": {"type": "number", "description": "Görsel/PDF döndürme açısı (derece)"},
          "crop": {
            "type": "array",
            "items": {"type": "integer"},
            "description": "Görsel kırpma [sol, üst, sağ, alt]"
          },
          "annotate_text": {"type": "string", "description": "Görsel üzerine yazılacak metin"},
          "grayscale": {"type": "boolean", "description": "Görseli siyah-beyaza çevir"},
          "start_sec": {"type": "number", "description": "Ses kırpma başlangıç saniyesi"},
          "end_sec": {"type": "number", "description": "Ses kırpma bitiş saniyesi"},
          "db_change": {"type": "number", "description": "Ses seviyesi değişimi (dB, örn: 3 veya -5)"},
          "speed": {"type": "number", "description": "Ses hızı çarpanı (0.5 - 2.0)"},
          "normalize": {"type": "boolean", "description": "Ses yüksekliğini normalize et (loudnorm)"},
          "artist": {"type": "string", "description": "Müzik sanatçı etiketi (ID3)"},
          "album": {"type": "string", "description": "Müzik albüm etiketi (ID3)"},
          "input_paths": {
            "type": "array",
            "items": {"type": "string"},
            "description": "PDF veya Ses birleştirme (merge) için kaynak dosya listesi"
          }
        },
        "required": ["output_path"]
      }
    }
  };

  static final Map<String, dynamic> openFileInSystemTool = {
    "type": "function",
    "function": {
      "name": "open_file_in_system",
      "description":
          "Bir dosyayı (Ofis, PDF, Resim, Müzik/Ses, AutoCAD .dwg/.dxf vb.) veya klasörü kullanıcının masaüstü varsayılan uygulamasıyla açar/görüntüler.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Masaüstünde açılacak dosya veya klasörün tam yolu"
          }
        },
        "required": ["path"]
      }
    }
  };

  // 4. Web Araçları
  static final Map<String, dynamic> searchWebTool = {
    "type": "function",
    "function": {
      "name": "search_web",
      "description":
          "İnternette güncel bilgi arar (Deep Research). Geriye sonuç özetleri ve kaynak URL'leri döner.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": {"type": "string", "description": "Arama sorgusu"}
        },
        "required": ["query"]
      }
    }
  };

  static final Map<String, dynamic> readUrlContentTool = {
    "type": "function",
    "function": {
      "name": "read_url_content",
      "description": "Bir web sayfasının içeriğini (HTML'den arındırılmış metin olarak) okur.",
      "parameters": {
        "type": "object",
        "properties": {
          "url": {"type": "string", "description": "Okunacak web sayfasının tam adresi"}
        },
        "required": ["url"]
      }
    }
  };

  // 5. Hafıza ve Beceriler
  static final Map<String, dynamic> todoWriteTool = {
    "type": "function",
    "function": {
      "name": "todo_write",
      "description":
          "Görev planını ve adım durumlarını günceller. Kullanıcı arayüzünde canlı todo listesini yeniler.",
      "parameters": {
        "type": "object",
        "properties": {
          "todos": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "id": {"type": "string", "description": "Adım ID (örn: step_1)"},
                "content": {"type": "string", "description": "Görev açıklaması"},
                "status": {
                  "type": "string",
                  "enum": ["pending", "in_progress", "completed"],
                  "description": "Adım durumu"
                }
              },
              "required": ["id", "content", "status"]
            },
            "description": "Güncel görev listesi"
          }
        },
        "required": ["todos"]
      }
    }
  };

  static final Map<String, dynamic> mcpCallTool = {
    "type": "function",
    "function": {
      "name": "mcp_call",
      "description":
          "Aktif bir MCP (Model Context Protocol) sunucusundaki aracı çağırır veya kaynak sorgular.",
      "parameters": {
        "type": "object",
        "properties": {
          "server_name": {
            "type": "string",
            "description": "Hedef MCP sunucusunun adı (örn: filesystem, fetch, memory, sqlite)"
          },
          "tool_name": {
            "type": "string",
            "description": "Çalıştırılacak MCP aracının adı"
          },
          "arguments": {
            "type": "object",
            "description": "Araca iletilecek parametreler"
          }
        },
        "required": ["server_name", "tool_name"]
      }
    }
  };

  static final Map<String, dynamic> saveSkillTool = {
    "type": "function",
    "function": {
      "name": "save_skill",
      "description":
          "Başarıyla tamamlanan bir iş akışını kalıcı beceri (skill) olarak kaydeder.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": {"type": "string", "description": "Beceri adı"},
          "description": {"type": "string", "description": "Becerinin ne işe yaradığı"},
          "instructions": {"type": "string", "description": "Adım adım uygulanacak talimatlar"}
        },
        "required": ["name", "description", "instructions"]
      }
    }
  };

  static final Map<String, dynamic> useSkillTool = {
    "type": "function",
    "function": {
      "name": "use_skill",
      "description": "Kayıtlı bir becerinin tam talimatını yükler.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": {"type": "string", "description": "Beceri adı"}
        },
        "required": ["name"]
      }
    }
  };

  static final Map<String, dynamic> recordExperienceTool = {
    "type": "function",
    "function": {
      "name": "record_experience",
      "description": "Tamamlanan görevin deneyim özetini hafızaya yazar.",
      "parameters": {
        "type": "object",
        "properties": {
          "summary": {"type": "string", "description": "Görevin ve sonucun 1-3 cümlelik özeti"},
          "tools_used": {"type": "string", "description": "Kullanılan ana araçlar"},
          "success": {"type": "boolean", "description": "Görev başarılı mıydı?"}
        },
        "required": ["summary", "success"]
      }
    }
  };

  // 6. Ajan Araçları
  static final Map<String, dynamic> spawnAgentTool = {
    "type": "function",
    "function": {
      "name": "spawn_agent",
      "description":
          "İzole bir alt-ajan (subagent) oluşturur. Büyük/bağımsız görevleri arka planda paralel çalıştırır.",
      "parameters": {
        "type": "object",
        "properties": {
          "goal": {"type": "string", "description": "Alt-ajana verilecek net görev tanımı"},
          "max_steps": {"type": "integer", "description": "Maksimum adım sayısı (varsayılan 50)"}
        },
        "required": ["goal"]
      }
    }
  };

  static final Map<String, dynamic> dispatchWorkerTool = {
    "type": "function",
    "function": {
      "name": "dispatch_worker",
      "description":
          "Uzun sürecek bir görevi arka plandaki işçi ajana devredip ana sohbete devam etmeyi sağlar.",
      "parameters": {
        "type": "object",
        "properties": {
          "goal": {"type": "string", "description": "İşçi ajanın yapacağı işin tanımı"}
        },
        "required": ["goal"]
      }
    }
  };

  // 7. Piyasa / Finans Araçları (Opsiyonel)
  static final Map<String, dynamic> checkMarketTool = {
    "type": "function",
    "function": {
      "name": "check_market",
      "description": "Kripto para veya hisse senedi canlı fiyatını, hacmini ve değişimini çeker.",
      "parameters": {
        "type": "object",
        "properties": {
          "asset_type": {"type": "string", "description": "Sadece 'crypto' veya 'stock' olabilir."},
          "symbol": {"type": "string", "description": "Varlık sembolü (örn. BTC, ETH, AAPL)"}
        },
        "required": ["asset_type", "symbol"]
      }
    }
  };

  static final Map<String, dynamic> analyzeMarketTool = {
    "type": "function",
    "function": {
      "name": "analyze_market",
      "description": "Bir varlığın teknik analizini (RSI, MACD) hesaplar ve yorumlar.",
      "parameters": {
        "type": "object",
        "properties": {
          "symbol": {"type": "string", "description": "Varlık sembolü (örn. BTC-USD, AAPL)"}
        },
        "required": ["symbol"]
      }
    }
  };

  /// Oturum türüne göre optimize edilmiş araç listesini döndürür.
  static List<Map<String, dynamic>> getToolsForSession({
    required bool isLiveSession,
    bool includeMarketTools = false,
  }) {
    final List<Map<String, dynamic>> tools = [
      runCommandTool,
      readFileTool,
      writeToFileTool,
      replaceFileContentTool,
      grepSearchTool,
      globTool,
      readDocumentTool,
      editMediaOrDocumentTool,
      openFileInSystemTool,
      searchWebTool,
      readUrlContentTool,
      todoWriteTool,
      saveSkillTool,
      useSkillTool,
      recordExperienceTool,
      mcpCallTool,
    ];

    if (isLiveSession) {
      tools.add(dispatchWorkerTool);
    } else {
      tools.add(spawnAgentTool);
    }

    if (includeMarketTools) {
      tools.add(checkMarketTool);
      tools.add(analyzeMarketTool);
    }

    return tools;
  }
}
