enum DistributionChannel {
    #if ZOOMIT_APP_STORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
}