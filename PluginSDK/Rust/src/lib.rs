//! Typed requests and responses for Dial Studio's import-free WebAssembly ABI.
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Serialize, Deserialize)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub version: String,
    pub kind: String,
    pub entrypoint: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    pub actions: Vec<Action>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Action {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relative: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fields: Option<Vec<Field>>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Field {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_value: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Context {
    #[serde(rename = "bundleID")]
    pub bundle_id: String,
    pub app_name: String,
    pub title: String,
    pub url: String,
}

#[derive(Debug, Deserialize)]
pub struct Request {
    pub action: String,
    pub context: Context,
    pub event: HashMap<String, String>,
    pub settings: HashMap<String, String>,
    pub amount: f64,
    pub profile: String,
    pub layer: String,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(rename = "openURL", skip_serializing_if = "Option::is_none")]
    pub open_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub open_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub open_application: Option<String>,
}

pub fn invoke(input: &[u8], handler: impl FnOnce(Request) -> Result<Response, String>) -> Vec<u8> {
    let result = serde_json::from_slice(input).map_err(|e| e.to_string()).and_then(handler)
        .unwrap_or_else(|error| Response { error: Some(error), ..Response::default() });
    serde_json::to_vec(&result).unwrap_or_else(|_| b"{\"error\":\"Encoding failed\"}".to_vec())
}

/// Export the ABI for a handler of type `fn(Request) -> Result<Response, String>`.
#[macro_export]
macro_rules! export_plugin {
    ($handler:path) => {
        std::thread_local! {
            static DIAL_INPUT: std::cell::RefCell<Vec<u8>> = std::cell::RefCell::new(Vec::new());
            static DIAL_OUTPUT: std::cell::RefCell<Vec<u8>> = std::cell::RefCell::new(Vec::new());
        }
        #[no_mangle]
        pub extern "C" fn dial_alloc(size: u32) -> *mut u8 {
            if size > 65536 { return std::ptr::null_mut(); }
            DIAL_INPUT.with(|buf| { let mut buf = buf.borrow_mut(); buf.resize(size as usize, 0); buf.as_mut_ptr() })
        }
        #[no_mangle]
        pub extern "C" fn dial_run(ptr: *const u8, len: u32) -> *const u8 {
            let result = DIAL_INPUT.with(|buf| {
                let buf = buf.borrow();
                if ptr != buf.as_ptr() || len as usize > buf.len() {
                    return b"{\"error\":\"Invalid request buffer\"}".to_vec();
                }
                $crate::invoke(&buf[..len as usize], $handler)
            });
            DIAL_OUTPUT.with(|buf| { let mut buf = buf.borrow_mut(); *buf = result; buf.as_ptr() })
        }
        #[no_mangle]
        pub extern "C" fn dial_result_len() -> u32 {
            DIAL_OUTPUT.with(|buf| buf.borrow().len() as u32)
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn request_and_error_round_trip() {
        let json = br#"{"action":"open","context":{"bundleID":"app","appName":"App","title":"","url":""},"event":{},"settings":{"url":"https://example.com"},"amount":1,"profile":"P","layer":"L"}"#;
        let result = invoke(json, |r| Ok(Response { open_url: r.settings.get("url").cloned(), ..Response::default() }));
        assert_eq!(serde_json::from_slice::<serde_json::Value>(&result).unwrap()["openURL"], "https://example.com");
        let error = invoke(b"bad", |_| Ok(Response::default()));
        assert!(serde_json::from_slice::<serde_json::Value>(&error).unwrap()["error"].is_string());
    }
    #[test]
    fn manifest_field_names_match_host() {
        let json = r#"{"id":"example","name":"Example","version":"1","kind":"wasm","entrypoint":"plugin.wasm","actions":[{"id":"go","title":"Go","fields":[{"id":"url","title":"URL","defaultValue":"https://example.com"}]}]}"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        let value = serde_json::to_value(manifest).unwrap();
        assert_eq!(value["actions"][0]["fields"][0]["defaultValue"], "https://example.com");
    }
}
