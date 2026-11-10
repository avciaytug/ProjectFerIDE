//! Masaüstü penceresi (tao + wry). Arayüz yerel sunucudan yüklenir; WebView kendi
//! süreçlerinde çizer, bu yüzden arayüzdeki bir çökme çekirdeği (ajan, model) düşürmez.

use std::sync::Arc;

use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::{Icon, WindowBuilder};
use wry::{WebContext, WebViewBuilder};

pub enum UserEvent {
    Quit,
}

/// Pencereyi açar ve kapanana kadar bekler. WebView açılamazsa `Err` döner
/// (çağıran taraf arayüzü varsayılan tarayıcıda açar).
pub fn run(url: String, origin: String, data_dir: std::path::PathBuf, quit: Arc<tokio::sync::Notify>, on_exit: impl FnOnce() + 'static) -> anyhow::Result<()> {
    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    // Arayüzden "Kapat" gelirse pencereyi kapat.
    std::thread::spawn({
        let quit = quit.clone();
        move || {
            let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            rt.block_on(quit.notified());
            let _ = proxy.send_event(UserEvent::Quit);
        }
    });

    let window = WindowBuilder::new()
        .with_title(format!("FerIDE {}", feride_core::DISPLAY_VERSION))
        .with_inner_size(LogicalSize::new(1440.0, 900.0))
        .with_min_inner_size(LogicalSize::new(900.0, 600.0))
        .with_window_icon(Some(app_icon()))
        .build(&event_loop)?;

    let mut ctx = WebContext::new(Some(data_dir));
    let origin_nav = origin.clone();
    let builder = WebViewBuilder::new_with_web_context(&mut ctx)
        .with_url(&url)
        .with_devtools(cfg!(debug_assertions))
        .with_navigation_handler(move |target: String| {
            // Yalnızca FerIDE'nin kendi adresi pencerede açılır; dış bağlantılar sistem tarayıcısında.
            if target.starts_with(&origin_nav) || target.starts_with("about:") || target.starts_with("data:") || target.starts_with("blob:") {
                true
            } else {
                if target.starts_with("http://") || target.starts_with("https://") {
                    let _ = open::that_detached(&target);
                }
                false
            }
        })
        .with_new_window_req_handler(move |target: String, _features| {
            if target.starts_with("http://") || target.starts_with("https://") {
                let _ = open::that_detached(&target);
            }
            wry::NewWindowResponse::Deny
        });

    #[cfg(not(target_os = "linux"))]
    let webview = builder.build(&window)?;
    #[cfg(target_os = "linux")]
    let webview = {
        use tao::platform::unix::WindowExtUnix;
        use wry::WebViewBuilderExtUnix;
        let vbox = window.default_vbox().ok_or_else(|| anyhow::anyhow!("GTK kutusu yok"))?;
        builder.build_gtk(vbox)?
    };

    let mut on_exit = Some(on_exit);
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        let _keep = (&webview, &ctx);
        match event {
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } | Event::UserEvent(UserEvent::Quit) => {
                if let Some(f) = on_exit.take() {
                    f();
                }
                // Temizlik bitti (alt süreçler kapatıldı, kilit dosyası silindi). Pencere/WebView
                // sökümü sırasında tao'nun "cannot move state from Destroyed" paniğine düşmemek için
                // süreç doğrudan sonlandırılır.
                *control_flow = ControlFlow::Exit;
                std::process::exit(0);
            }
            _ => {}
        }
    });
}

/// Uygulama simgesi (çalışma zamanında çizilir: mor-turkuaz degrade üzerinde "F").
fn app_icon() -> Icon {
    const N: u32 = 64;
    let mut rgba = Vec::with_capacity((N * N * 4) as usize);
    for y in 0..N {
        for x in 0..N {
            let (fx, fy) = (x as f32 / N as f32, y as f32 / N as f32);
            let r = 8.0 / 64.0;
            let inside = {
                let cx = fx.clamp(r, 1.0 - r);
                let cy = fy.clamp(r, 1.0 - r);
                ((fx - cx).powi(2) + (fy - cy).powi(2)).sqrt() <= r
            };
            if !inside {
                rgba.extend_from_slice(&[0, 0, 0, 0]);
                continue;
            }
            let t = (fx + fy) / 2.0;
            let mut c = [(124.0 * (1.0 - t) + 34.0 * t) as u8, (92.0 * (1.0 - t) + 211.0 * t) as u8, (255.0 * (1.0 - t) + 238.0 * t) as u8, 255];
            // "F" harfi
            let in_stem = (0.30..0.42).contains(&fx) && (0.22..0.80).contains(&fy);
            let in_top = (0.30..0.72).contains(&fx) && (0.22..0.33).contains(&fy);
            let in_mid = (0.30..0.64).contains(&fx) && (0.46..0.56).contains(&fy);
            if in_stem || in_top || in_mid {
                c = [255, 255, 255, 255];
            }
            rgba.extend_from_slice(&c);
        }
    }
    Icon::from_rgba(rgba, N, N).expect("simge")
}
