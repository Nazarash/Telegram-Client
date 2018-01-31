import Foundation
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import LegacyComponents

private final class SettingsItemIcons {
    static let savedMessages = UIImage(bundleImageName: "Settings/MenuIcons/SavedMessages")?.precomposed()
    static let recentCalls = UIImage(bundleImageName: "Settings/MenuIcons/RecentCalls")?.precomposed()
    static let stickers = UIImage(bundleImageName: "Settings/MenuIcons/Stickers")?.precomposed()
    
    static let notifications = UIImage(bundleImageName: "Settings/MenuIcons/Notifications")?.precomposed()
    static let security = UIImage(bundleImageName: "Settings/MenuIcons/Security")?.precomposed()
    static let dataAndStorage = UIImage(bundleImageName: "Settings/MenuIcons/DataAndStorage")?.precomposed()
    static let appearance = UIImage(bundleImageName: "Settings/MenuIcons/Appearance")?.precomposed()
    static let language = UIImage(bundleImageName: "Settings/MenuIcons/Language")?.precomposed()
    
    static let support = UIImage(bundleImageName: "Settings/MenuIcons/Support")?.precomposed()
    static let faq = UIImage(bundleImageName: "Settings/MenuIcons/Faq")?.precomposed()
}

private struct SettingsItemArguments {
    let account: Account
    let accountManager: AccountManager
    let avatarAndNameInfoContext: ItemListAvatarAndNameInfoItemContext
    
    let avatarTapAction: () -> Void
    
    let changeProfilePhoto: () -> Void
    let openUsername: () -> Void
    let openSavedMessages: () -> Void
    let openRecentCalls: () -> Void
    let openPrivacyAndSecurity: () -> Void
    let openDataAndStorage: () -> Void
    let openThemes: () -> Void
    let pushController: (ViewController) -> Void
    let presentController: (ViewController) -> Void
    let openLanguage: () -> Void
    let openSupport: () -> Void
    let openFaq: () -> Void
    let openEditing: () -> Void
}

private enum SettingsSection: Int32 {
    case info
    case media
    case generalSettings
    case help
    case debug
}

private enum SettingsEntry: ItemListNodeEntry {
    case userInfo(PresentationTheme, PresentationStrings, Peer?, CachedPeerData?, ItemListAvatarAndNameInfoItemState, ItemListAvatarAndNameInfoItemUpdatingAvatar?)
    case setProfilePhoto(PresentationTheme, String)
    case setUsername(PresentationTheme, String)
    
    case savedMessages(PresentationTheme, UIImage?, String)
    case recentCalls(PresentationTheme, UIImage?, String)
    case stickers(PresentationTheme, UIImage?, String)
    
    case notificationsAndSounds(PresentationTheme, UIImage?, String)
    case privacyAndSecurity(PresentationTheme, UIImage?, String)
    case dataAndStorage(PresentationTheme, UIImage?, String)
    case themes(PresentationTheme, UIImage?, String)
    case language(PresentationTheme, UIImage?, String, String)
    
    case askAQuestion(PresentationTheme, UIImage?, String)
    case faq(PresentationTheme, UIImage?, String)
    case debug(PresentationTheme, String)
    
    var section: ItemListSectionId {
        switch self {
            case .userInfo, .setProfilePhoto, .setUsername:
                return SettingsSection.info.rawValue
            case .savedMessages, .recentCalls, .stickers:
                return SettingsSection.media.rawValue
        case .notificationsAndSounds, .privacyAndSecurity, .dataAndStorage, .themes, .language:
                return SettingsSection.generalSettings.rawValue
            case .askAQuestion, .faq:
                return SettingsSection.help.rawValue
            case .debug:
                return SettingsSection.debug.rawValue
        }
    }
    
    var stableId: Int32 {
        switch self {
            case .userInfo:
                return 0
            case .setProfilePhoto:
                return 1
            case .setUsername:
                return 2
            case .savedMessages:
                return 3
            case .recentCalls:
                return 4
            case .stickers:
                return 5
            case .notificationsAndSounds:
                return 6
            case .privacyAndSecurity:
                return 7
            case .dataAndStorage:
                return 8
            case .themes:
                return 9
            case .language:
                return 10
            case .askAQuestion:
                return 11
            case .faq:
                return 12
            case .debug:
                return 13
        }
    }
    
    static func ==(lhs: SettingsEntry, rhs: SettingsEntry) -> Bool {
        switch lhs {
            case let .userInfo(lhsTheme, lhsStrings, lhsPeer, lhsCachedData, lhsEditingState, lhsUpdatingImage):
                if case let .userInfo(rhsTheme, rhsStrings, rhsPeer, rhsCachedData, rhsEditingState, rhsUpdatingImage) = rhs {
                    if lhsTheme !== rhsTheme {
                        return false
                    }
                    if lhsStrings !== rhsStrings {
                        return false
                    }
                    if let lhsPeer = lhsPeer, let rhsPeer = rhsPeer {
                        if !lhsPeer.isEqual(rhsPeer) {
                            return false
                        }
                    } else if (lhsPeer != nil) != (rhsPeer != nil) {
                        return false
                    }
                    if let lhsCachedData = lhsCachedData, let rhsCachedData = rhsCachedData {
                        if !lhsCachedData.isEqual(to: rhsCachedData) {
                            return false
                        }
                    } else if (lhsCachedData != nil) != (rhsCachedData != nil) {
                        return false
                    }
                    if lhsEditingState != rhsEditingState {
                        return false
                    }
                    if lhsUpdatingImage != rhsUpdatingImage {
                        return false
                    }
                    return true
                } else {
                    return false
                }
            case let .setProfilePhoto(lhsTheme, lhsText):
                if case let .setProfilePhoto(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .setUsername(lhsTheme, lhsText):
                if case let .setUsername(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .savedMessages(lhsTheme, lhsImage, lhsText):
                if case let .savedMessages(rhsTheme, rhsImage, rhsText) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .recentCalls(lhsTheme, lhsImage, lhsText):
                if case let .recentCalls(rhsTheme, rhsImage, rhsText) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .stickers(lhsTheme, lhsImage, lhsText):
                if case let .stickers(rhsTheme, rhsImage, rhsText) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .notificationsAndSounds(lhsTheme, lhsImage, lhsText):
                if case let .notificationsAndSounds(rhsTheme, rhsImage, rhsText) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .privacyAndSecurity(lhsTheme, lhsImage, lhsText):
                if case let .privacyAndSecurity(rhsTheme, rhsImage, rhsText) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .dataAndStorage(lhsTheme, lhsImage, lhsText):
                if case let .dataAndStorage(rhsTheme, rhsImage, rhsText) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .themes(lhsTheme, lhsImage, lhsText):
                if case let .themes(rhsTheme, rhsImage, rhsText) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .language(lhsTheme, lhsImage, lhsText, lhsValue):
                if case let .language(rhsTheme, rhsImage, rhsText, rhsValue) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText, lhsValue == rhsValue {
                    return true
                } else {
                    return false
                }
            case let .askAQuestion(lhsTheme, lhsImage, lhsText):
                if case let .askAQuestion(rhsTheme, rhsImage, rhsText) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .faq(lhsTheme, lhsImage, lhsText):
                if case let .faq(rhsTheme, rhsImage, rhsText) = rhs, lhsTheme === rhsTheme, lhsImage === rhsImage, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .debug(lhsTheme, lhsText):
                if case let .debug(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
        }
    }
    
    static func <(lhs: SettingsEntry, rhs: SettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
    
    func item(_ arguments: SettingsItemArguments) -> ListViewItem {
        switch self {
            case let .userInfo(theme, strings, peer, cachedData, state, updatingImage):
                return ItemListAvatarAndNameInfoItem(account: arguments.account, theme: theme, strings: strings, mode: .settings, peer: peer, presence: TelegramUserPresence(status: .present(until: Int32.max)), cachedData: cachedData, state: state, sectionId: ItemListSectionId(self.section), style: .blocks(withTopInset: false), editingNameUpdated: { _ in
                }, avatarTapped: {
                    arguments.avatarTapAction()
                }, context: arguments.avatarAndNameInfoContext, updatingImage: updatingImage, action: {
                    arguments.openEditing()
                })
            case let .setProfilePhoto(theme, text):
                return ItemListActionItem(theme: theme, title: text, kind: .generic, alignment: .natural, sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.changeProfilePhoto()
                })
            case let .setUsername(theme, text):
                return ItemListActionItem(theme: theme, title: text, kind: .generic, alignment: .natural, sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.openUsername()
                })
            case let .savedMessages(theme, image, text):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.openSavedMessages()
                })
            case let .recentCalls(theme, image, text):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.openRecentCalls()
                })
            case let .stickers(theme, image, text):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.pushController(installedStickerPacksController(account: arguments.account, mode: .general))
                })
            case let .notificationsAndSounds(theme, image, text):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.pushController(notificationsAndSoundsController(account: arguments.account))
                })
            case let .privacyAndSecurity(theme, image, text):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.openPrivacyAndSecurity()
                })
            case let .dataAndStorage(theme, image, text):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.openDataAndStorage()
                })
            case let .themes(theme, image, text):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.openThemes()
                })
            case let .language(theme, image, text, value):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: value, sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.openLanguage()
                })
            case let .askAQuestion(theme, image, text):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.openSupport()
                })
            case let .faq(theme, image, text):
                return ItemListDisclosureItem(theme: theme, icon: image, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.openFaq()
                })
            case let .debug(theme, text):
                return ItemListDisclosureItem(theme: theme, title: text, label: "", sectionId: ItemListSectionId(self.section), style: .blocks, action: {
                    arguments.pushController(debugController(account: arguments.account, accountManager: arguments.accountManager))
                })
        }
    }
}

private struct SettingsState: Equatable {
    let updatingAvatar: ItemListAvatarAndNameInfoItemUpdatingAvatar?
    
    init(updatingAvatar: ItemListAvatarAndNameInfoItemUpdatingAvatar? = nil) {
        self.updatingAvatar = updatingAvatar
    }
    
    func withUpdatedUpdatingAvatar(_ updatingAvatar: ItemListAvatarAndNameInfoItemUpdatingAvatar?) -> SettingsState {
        return SettingsState(updatingAvatar: updatingAvatar)
    }
    
    static func ==(lhs: SettingsState, rhs: SettingsState) -> Bool {
        if lhs.updatingAvatar != rhs.updatingAvatar {
            return false
        }
        return true
    }
}

private func settingsEntries(presentationData: PresentationData, state: SettingsState, view: PeerView) -> [SettingsEntry] {
    var entries: [SettingsEntry] = []
    
    if let peer = peerViewMainPeer(view) as? TelegramUser {
        let userInfoState = ItemListAvatarAndNameInfoItemState(editingName: nil, updatingName: nil)
        entries.append(.userInfo(presentationData.theme, presentationData.strings, peer, view.cachedData, userInfoState, state.updatingAvatar))
        if peer.photo.isEmpty {
            entries.append(.setProfilePhoto(presentationData.theme, presentationData.strings.Settings_SetProfilePhoto))
        }
        if peer.addressName == nil {
            entries.append(.setUsername(presentationData.theme, presentationData.strings.Settings_SetUsername))
        }
        
        entries.append(.savedMessages(presentationData.theme, SettingsItemIcons.savedMessages, presentationData.strings.Settings_SavedMessages))
        entries.append(.recentCalls(presentationData.theme, SettingsItemIcons.recentCalls, presentationData.strings.CallSettings_RecentCalls))
        entries.append(.stickers(presentationData.theme, SettingsItemIcons.stickers, presentationData.strings.ChatSettings_Stickers))
        
        entries.append(.notificationsAndSounds(presentationData.theme, SettingsItemIcons.notifications, presentationData.strings.Settings_NotificationsAndSounds))
        entries.append(.privacyAndSecurity(presentationData.theme, SettingsItemIcons.security, presentationData.strings.Settings_PrivacySettings))
        entries.append(.dataAndStorage(presentationData.theme, SettingsItemIcons.dataAndStorage, presentationData.strings.Settings_ChatSettings))
        entries.append(.themes(presentationData.theme, SettingsItemIcons.appearance, presentationData.strings.ChatSettings_Appearance.lowercased().capitalized))
        entries.append(.language(presentationData.theme, SettingsItemIcons.language, presentationData.strings.Settings_AppLanguage, presentationData.strings.Localization_LanguageName))
        
        entries.append(.askAQuestion(presentationData.theme, SettingsItemIcons.support, presentationData.strings.Settings_Support))
        entries.append(.faq(presentationData.theme, SettingsItemIcons.faq, presentationData.strings.Settings_FAQ))
        
        if !GlobalExperimentalSettings.isAppStoreBuild {
            entries.append(.debug(presentationData.theme, "Debug"))
        }
    }
    
    return entries
}

public func settingsController(account: Account, accountManager: AccountManager) -> ViewController {
    let statePromise = ValuePromise(SettingsState(), ignoreRepeated: true)
    let stateValue = Atomic(value: SettingsState())
    let updateState: ((SettingsState) -> SettingsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController, Any?) -> Void)?
    
    let actionsDisposable = DisposableSet()
    
    let cachedDataDisposable = MetaDisposable()
    actionsDisposable.add(cachedDataDisposable)
    
    let updateAvatarDisposable = MetaDisposable()
    actionsDisposable.add(updateAvatarDisposable)
    
    let updatePeerNameDisposable = MetaDisposable()
    actionsDisposable.add(updatePeerNameDisposable)
    
    let supportPeerDisposable = MetaDisposable()
    actionsDisposable.add(supportPeerDisposable)
    
    let hiddenAvatarRepresentationDisposable = MetaDisposable()
    actionsDisposable.add(hiddenAvatarRepresentationDisposable)
    
    let currentAvatarMixin = Atomic<TGMediaAvatarMenuMixin?>(value: nil)
    
    var avatarGalleryTransitionArguments: ((AvatarGalleryEntry) -> GalleryTransitionArguments?)?
    let avatarAndNameInfoContext = ItemListAvatarAndNameInfoItemContext()
    var updateHiddenAvatarImpl: (() -> Void)?
    var changeProfilePhotoImpl: (() -> Void)?
    var openSavedMessagesImpl: (() -> Void)?
    
    let arguments = SettingsItemArguments(account: account, accountManager: accountManager, avatarAndNameInfoContext: avatarAndNameInfoContext, avatarTapAction: {
        var updating = false
        updateState {
            updating = $0.updatingAvatar != nil
            return $0
        }
        
        if updating {
            return
        }
        
        let _ = (account.postbox.loadedPeerWithId(account.peerId) |> take(1) |> deliverOnMainQueue).start(next: { peer in
            if peer.smallProfileImage != nil {
                let galleryController = AvatarGalleryController(account: account, peer: peer, replaceRootController: { controller, ready in
                    
                })
                hiddenAvatarRepresentationDisposable.set((galleryController.hiddenMedia |> deliverOnMainQueue).start(next: { entry in
                    avatarAndNameInfoContext.hiddenAvatarRepresentation = entry?.representations.first
                    updateHiddenAvatarImpl?()
                }))
                presentControllerImpl?(galleryController, AvatarGalleryControllerPresentationArguments(transitionArguments: { entry in
                    return avatarGalleryTransitionArguments?(entry)
                }))
            } else {
                changeProfilePhotoImpl?()
            }
        })
    }, changeProfilePhoto: {
        changeProfilePhotoImpl?()
    }, openUsername: {
        presentControllerImpl?(usernameSetupController(account: account), nil)
    }, openSavedMessages: {
        openSavedMessagesImpl?()
    }, openRecentCalls: {
        pushControllerImpl?(CallListController(account: account, mode: .navigation))
    }, openPrivacyAndSecurity: {
        pushControllerImpl?(privacyAndSecurityController(account: account, initialSettings: .single(nil) |> then(requestAccountPrivacySettings(account: account) |> map { Optional($0) })))
    }, openDataAndStorage: {
        pushControllerImpl?(dataAndStorageController(account: account))
    }, openThemes: {
        pushControllerImpl?(themeSettingsController(account: account))
    }, pushController: { controller in
        pushControllerImpl?(controller)
    }, presentController: { controller in
        presentControllerImpl?(controller, nil)
    }, openLanguage: {
        let controller = LanguageSelectionController(account: account)
        presentControllerImpl?(controller, nil)
    }, openSupport: {
        supportPeerDisposable.set((supportPeerId(account: account) |> deliverOnMainQueue).start(next: { peerId in
            if let peerId = peerId {
                pushControllerImpl?(ChatController(account: account, chatLocation: .peer(peerId)))
            }
        }))
    }, openFaq: {
        let presentationData = account.telegramApplicationContext.currentPresentationData.with { $0 }
        var faqUrl = presentationData.strings.Settings_FAQ_URL
        if faqUrl == "Settings.FAQ_URL" || faqUrl.isEmpty {
            faqUrl = "http://telegram.org/faq#general"
        }
        
        if let applicationContext = account.applicationContext as? TelegramApplicationContext {
            applicationContext.applicationBindings.openUrl(faqUrl)
        }
    }, openEditing: {
        let _ = (account.postbox.modify { modifier -> (Peer?, CachedPeerData?) in
            return (modifier.getPeer(account.peerId), modifier.getPeerCachedData(peerId: account.peerId))
        } |> deliverOnMainQueue).start(next: { peer, cachedData in
            if let peer = peer as? TelegramUser, let cachedData = cachedData as? CachedUserData {
                pushControllerImpl?(editSettingsController(account: account, currentName: .personName(firstName: peer.firstName ?? "", lastName: peer.lastName ?? ""), currentBioText: cachedData.about ?? "", accountManager: accountManager))
            }
        })
    })
    
    changeProfilePhotoImpl = {
        let _ = (account.postbox.modify { modifier -> Peer? in
            return modifier.getPeer(account.peerId)
            } |> deliverOnMainQueue).start(next: { peer in
                let presentationData = account.telegramApplicationContext.currentPresentationData.with { $0 }
                
                let legacyController = LegacyController(presentation: .custom, theme: presentationData.theme)
                legacyController.statusBar.statusBarStyle = .Ignore
                
                let emptyController = LegacyEmptyController(context: legacyController.context)!
                let navigationController = makeLegacyNavigationController(rootController: emptyController)
                navigationController.setNavigationBarHidden(true, animated: false)
                navigationController.navigationBar.transform = CGAffineTransform(translationX: -1000.0, y: 0.0)
                
                legacyController.bind(controller: navigationController)
                
                presentControllerImpl?(legacyController, nil)
                
                var hasPhotos = false
                if let peer = peer, !peer.profileImageRepresentations.isEmpty {
                    hasPhotos = true
                }
                
                let mixin = TGMediaAvatarMenuMixin(context: legacyController.context, parentController: emptyController, hasDeleteButton: hasPhotos, personalPhoto: true, saveEditedPhotos: false, saveCapturedMedia: false)!
                let _ = currentAvatarMixin.swap(mixin)
                mixin.didFinishWithImage = { image in
                    if let image = image {
                        if let data = UIImageJPEGRepresentation(image, 0.6) {
                            let resource = LocalFileMediaResource(fileId: arc4random64())
                            account.postbox.mediaBox.storeResourceData(resource.id, data: data)
                            let representation = TelegramMediaImageRepresentation(dimensions: CGSize(width: 640.0, height: 640.0), resource: resource)
                            updateState {
                                $0.withUpdatedUpdatingAvatar(.image(representation))
                            }
                            updateAvatarDisposable.set((updateAccountPhoto(account: account, resource: resource) |> deliverOnMainQueue).start(next: { result in
                                switch result {
                                case .complete:
                                    updateState {
                                        $0.withUpdatedUpdatingAvatar(nil)
                                    }
                                case .progress:
                                    break
                                }
                            }))
                        }
                    }
                }
                mixin.didFinishWithDelete = {
                    let _ = currentAvatarMixin.swap(nil)
                    updateState {
                        if let profileImage = peer?.smallProfileImage {
                            return $0.withUpdatedUpdatingAvatar(.image(profileImage))
                        } else {
                            return $0.withUpdatedUpdatingAvatar(.none)
                        }
                    }
                    updateAvatarDisposable.set((updateAccountPhoto(account: account, resource: nil) |> deliverOnMainQueue).start(next: { result in
                        switch result {
                        case .complete:
                            updateState {
                                $0.withUpdatedUpdatingAvatar(nil)
                            }
                        case .progress:
                            break
                        }
                    }))
                }
                mixin.didDismiss = { [weak legacyController] in
                    let _ = currentAvatarMixin.swap(nil)
                    legacyController?.dismiss()
                }
                let menuController = mixin.present()
                if let menuController = menuController {
                    menuController.customRemoveFromParentViewController = { [weak legacyController] in
                        legacyController?.dismiss()
                    }
                }
            })
    }
    
    let peerView = account.viewTracker.peerView(account.peerId)
    
    let signal = combineLatest((account.applicationContext as! TelegramApplicationContext).presentationData, statePromise.get(), peerView)
        |> map { presentationData, state, view -> (ItemListControllerState, (ItemListNodeState<SettingsEntry>, SettingsEntry.ItemGenerationArguments)) in
            let peer = peerViewMainPeer(view)
            let rightNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Edit), style: .regular, enabled: true, action: {
                if let peer = peer as? TelegramUser, let cachedData = view.cachedData as? CachedUserData {
                    arguments.openEditing()
                }
            })
            
            let controllerState = ItemListControllerState(theme: presentationData.theme, title: .text(presentationData.strings.Settings_Title), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
            let listState = ItemListNodeState(entries: settingsEntries(presentationData: presentationData, state: state, view: view), style: .blocks)
            
            return (controllerState, (listState, arguments))
    } |> afterDisposed {
        actionsDisposable.dispose()
    }
    
    let controller = ItemListController(account: account, state: signal, tabBarItem: (account.applicationContext as! TelegramApplicationContext).presentationData |> map { presentationData in
        return ItemListControllerTabBarItem(title: presentationData.strings.Settings_Title, image: PresentationResourcesRootController.tabSettingsIcon(presentationData.theme), selectedImage: PresentationResourcesRootController.tabSettingsSelectedIcon(presentationData.theme))
    })
    pushControllerImpl = { [weak controller] value in
        (controller?.navigationController as? NavigationController)?.pushViewController(value)
    }
    presentControllerImpl = { [weak controller] value, arguments in
        controller?.present(value, in: .window(.root), with: arguments ?? ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }
    avatarGalleryTransitionArguments = { [weak controller] entry in
        if let controller = controller {
            var result: (ASDisplayNode, CGRect)?
            controller.forEachItemNode { itemNode in
                if let itemNode = itemNode as? ItemListAvatarAndNameInfoItemNode {
                    result = itemNode.avatarTransitionNode()
                }
            }
            if let (node, _) = result {
                return GalleryTransitionArguments(transitionNode: node, addToTransitionSurface: { _ in
                })
            }
        }
        return nil
    }
    updateHiddenAvatarImpl = { [weak controller] in
        if let controller = controller {
            controller.forEachItemNode { itemNode in
                if let itemNode = itemNode as? ItemListAvatarAndNameInfoItemNode {
                    itemNode.updateAvatarHidden()
                }
            }
        }
    }
    openSavedMessagesImpl = { [weak controller] in
        if let controller = controller, let navigationController = controller.navigationController as? NavigationController {
            navigateToChatController(navigationController: navigationController, account: account, chatLocation: .peer(account.peerId))
        }
    }
    return controller
}

