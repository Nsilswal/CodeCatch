import Foundation

struct Settings {
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: [
            "enabled": true,
            "notify": true,
            "autoClear": false,
            "onboarded": false,
        ])
    }

    var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        nonmutating set { d.set(newValue, forKey: "enabled") }
    }

    var notify: Bool {
        get { d.bool(forKey: "notify") }
        nonmutating set { d.set(newValue, forKey: "notify") }
    }

    /// Clear the clipboard 2 minutes after a copy if it still holds the code.
    var autoClear: Bool {
        get { d.bool(forKey: "autoClear") }
        nonmutating set { d.set(newValue, forKey: "autoClear") }
    }

    /// The user has seen the onboarding window (finished or closed it).
    var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        nonmutating set { d.set(newValue, forKey: "onboarded") }
    }
}
