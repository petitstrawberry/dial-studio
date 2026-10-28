use dial_plugin_sdk::{export_plugin, Request, Response};

fn handle(request: Request) -> Result<Response, String> {
    if request.action != "open" { return Err("Unknown action".into()); }
    let url = request.settings.get("url").filter(|s| !s.is_empty()).ok_or("URL is required")?;
    Ok(Response { open_url: Some(url.clone()), ..Response::default() })
}

export_plugin!(handle);
