import DialPluginSDK

@_cdecl("dial_plugin_run")
public func dialPluginRun(_ input: UnsafePointer<CChar>?) -> UnsafePointer<CChar>? {
    PluginRuntime.invoke(input) { request in
        guard request.action == "open" else { return PluginResponse(error: "Unknown action") }
        guard let url = request.settings["url"], !url.isEmpty else { return PluginResponse(error: "URL is required") }
        return PluginResponse(openURL: url)
    }
}
