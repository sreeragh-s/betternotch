import AVFoundation
import Testing
@testable import BetterNotch

@Test @MainActor func permissionStatusRefreshDoesNotPromptOrCacheGrants() {
    var microphone = AVAuthorizationStatus.notDetermined, screen = false, requests = 0
    var access = PermissionAccess()
    access.microphoneStatus = { microphone }; access.screenStatus = { screen }
    access.requestMicrophone = { requests += 1; return true }; access.requestScreen = { requests += 1; return true }
    let model = PermissionSettingsModel(access: access)
    #expect(model.microphoneLabel == "Not requested"); #expect(!model.screenAllowed)
    microphone = .authorized; screen = true; model.refresh()
    #expect(model.microphoneLabel == "Allowed"); #expect(model.screenAllowed)
    microphone = .denied; screen = false; model.refresh()
    #expect(model.microphoneLabel == "Not allowed"); #expect(!model.screenAllowed)
    #expect(requests == 0)
}

@Test @MainActor func deniedMicrophoneOpensSettingsWithoutRequestingAgain() async {
    var requests = 0, opened: [PrivacyPane] = []
    var access = PermissionAccess()
    access.microphoneStatus = { .denied }; access.screenStatus = { false }
    access.requestMicrophone = { requests += 1; return false }; access.openSettings = { opened.append($0); return true }
    let model = PermissionSettingsModel(access: access)
    await model.requestMicrophone()
    #expect(requests == 0); #expect(opened == [.microphone])
}

@Test @MainActor func microphoneRequestRefreshesStatusAndNeverReRequestsAnAllowedGrant() async {
    var status = AVAuthorizationStatus.notDetermined, requests = 0
    var access = PermissionAccess()
    access.microphoneStatus = { status }; access.screenStatus = { false }
    access.requestMicrophone = { requests += 1; status = .authorized; return true }
    let model = PermissionSettingsModel(access: access)
    await model.requestMicrophone(); await model.requestMicrophone()
    #expect(requests == 1); #expect(model.microphone == .authorized); #expect(!model.requestingMicrophone)
}

@Test @MainActor func screenRequestIsExplicitAndStatusUsesPreflightRatherThanTheRequestReturnValue() {
    var allowed = false, requests = 0
    var access = PermissionAccess()
    access.microphoneStatus = { .authorized }; access.screenStatus = { allowed }
    access.requestScreen = { requests += 1; return true }
    let model = PermissionSettingsModel(access: access)
    #expect(requests == 0)
    model.requestScreen(); model.requestScreen()
    #expect(requests == 1); #expect(!model.screenAllowed); #expect(!model.message.isEmpty)
    allowed = true; model.refresh()
    #expect(model.screenAllowed); #expect(model.message.isEmpty)
    allowed = false; model.refresh(); #expect(!model.screenAllowed)
}
