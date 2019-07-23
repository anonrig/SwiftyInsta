//
//  APIHandler.swift
//  SwiftyInsta
//
//  Created by Mahdi on 10/24/18.
//  V. 2.0 by Stefano Bertagno on 7/21/19.
//  Copyright © 2018 Mahdi. All rights reserved.
//

import Foundation

/// The `Instagram Private API` client.
public class APIHandler {
    /// A struct used to initialize `APIHandler`s.
    public struct Settings {
        /// A struct used to manage `DispatchQueue`s.
        public struct Queues {
            /// The queue used to prepare requests. Defaults to `DispatchQueue.main`.
            public var request: DispatchQueue
            /// The queue used for parsing and heavy lifting. Defaults to `DispatchQueue.global(qos: .userInitiated)`.
            public var working: DispatchQueue
            /// The queue used to deliver responses. Defaults to `DispatchQueue.main`.
            public var response: DispatchQueue
            
            public init(request: DispatchQueue = .main,
                        working: DispatchQueue = .global(qos: .userInitiated),
                        response: DispatchQueue = .main) {
                self.request = request
                self.working = working
                self.response = response
            }
        }
        
        /// The delay. Defaults to `1...2`. `nil` for no delay.
        public var delay: ClosedRange<Double>?
        /// The queue used to deliver responses. Defaults to `DispatchQueue.global(qos: .utility)`.
        public var queues: Queues
        /// The device. Defaults to a random device.
        public var device: AndroidDeviceModel { didSet { headers[Headers.HeaderUserAgentKey] = device.userAgent.string }}
        /// The url session. Defaults to `.shared`.
        public var session: URLSession
        /// The default headers. Defaults to `[:]`.
        var headers: [String: String] = [:]
        
        public init(delay: ClosedRange<Double>? = 1...2,
                    queues: Queues = .init(),
                    device: AndroidDeviceModel? = nil,
                    session: URLSession = .shared) {
            self.delay = delay
            self.queues = queues
            self.device = device ?? AndroidDeviceGenerator.getRandomAndroidDevice()
            self.session = session
        }
    }
    
    /// The settings.
    public var settings: Settings
    /// The login response.
    public var response: Login.Response?
    /// The authenticated user.
    public var user: CurrentUser? { return response?.cache?.storage?.user }
    
    // MARK: Init
    /// Create an instance of `APIHandler`.
    public init(with settings: Settings = .init()) {
        self.settings = settings
    }
        
    // MARK: Authentication
    /// Authenticate with the selected login method.
    public func authenticate(with request: Login.Request,
                             completionHandler: @escaping (Result<(Login.Response, APIHandler), Error>) -> Void) {
        switch request {
        case .cache(let cache):
            users.authenticate(cache: cache) { [weak self] response in
                guard let handler = self else { return completionHandler(.failure(CustomErrors.runTimeError("`weak` reference was released."))) }
                handler.settings.queues.response.async {
                    completionHandler(response.map { ($0, handler) })
                }
            }
        case .webView(let webView):
            webView.authenticate { [weak self] in
                guard let handler = self else { return completionHandler(.failure(CustomErrors.weakReferenceReleased)) }
                // check for cookies.
                switch $0 {
                case .failure(let error): completionHandler(.failure(error))
                case .success(let instagramCookies):
                    let cookies = instagramCookies.filter({ $0.domain.contains("instagram.com") })
                    let filtered = cookies.filter { $0.name == "ds_user_id" || $0.name == "csrftoken" || $0.name == "sessionid" }
                    guard filtered.count >= 3 else {
                        return handler.settings.queues.response.async {
                            completionHandler(.failure(CustomErrors.runTimeError("Invalid `SessionCache` response.")))
                        }
                    }
                    // prepare cache.
                    let dsUserId = filtered.first(where: { $0.name == "ds_user_id" })!.value
                    let csrfToken = filtered.first(where: { $0.name == "csrftoken" })!.value
                    let sessionId = filtered.first(where: { $0.name == "sessionid" })!.value
                    let rankToken = dsUserId+"_"+handler.settings.device.phoneGuid.uuidString
                    let cache = SessionCache(storage: SessionStorage(dsUserId: dsUserId,
                                                                     user: nil,
                                                                     csrfToken: csrfToken,
                                                                     sessionId: sessionId,
                                                                     rankToken: rankToken),
                                             device: handler.settings.device,
                                             cookies: cookies.toCookieData())
                    handler.authenticate(with: .cache(cache), completionHandler: completionHandler)
                }
            }
        }
    }
        
    /// Log out.
    public func invalidate(completionHandler: @escaping (Result<Bool, Error>) -> Void) throws {
        users.logOut { [weak self] in
            // empty response if needed.
            if (try? $0.get()) == true { self?.response = nil }
            completionHandler($0)
        }
    }
    
    // MARK: Helpers
    /// Accessory for `HttpHelper(handler: self)`.
    internal lazy var requests: HttpHelper = .init(handler: self)
    /// Accessory for `PaginationHelper(handler: self)`.
    internal lazy var pages: PaginationHelper = .init(handler: self)

    // MARK: Handlers
    /// `UserHandler` endpoints manager.
    public private(set) lazy var users: UserHandler = .init(handler: self)
    /// `CommentHandler` endpoints manager.
    public private(set) lazy var comments: CommentHandler = .init(handler: self)
    /// `FeedHandler` endpoints manager.
    public private(set) lazy var feeds: FeedHandler = .init(handler: self)
    /// `MediaHandler` endpoints manager.
    public private(set) lazy var media: MediaHandler = .init(handler: self)
    /// `MessageHandler` endpoints manager.
    public private(set) lazy var messages: MessageHandler = .init(handler: self)
    /// `ProfileHandler` endpoints manager.
    public private(set) lazy var profile: ProfileHandler = .init(handler: self)
    /// `StoryHandler` endpoints manager.
    public private(set) lazy var stories: StoryHandler = .init(handler: self)
}

// MARK: Other
/// An abstract `struct` holding login references .
public struct Login {
    public enum Request {
        @available(*, unavailable, message: "use `Siwa` instead to manage custom log in. (https://github.com/TheM4hd1/Siwa)")
        /// Log in with username and password. **Use  `Siwa` instead ** (https://github.com/TheM4hd1/Siwa)
        case user(String, password: String)
                
        @available(iOS 11, *)
        /// Log in through web view.
        case webView(LoginWebView)
        
        @available(iOS 10, *)   // `@available(_)` added simply to avoid a visual glitch in Xcode
        /// Log in using `SessionCache` (either a stored one, or through `Siwa`).
        case cache(SessionCache)
    }
    public struct Response {
        /// The login model.
        public var model: LoginResultModel
        /// The session cache.
        public var cache: SessionCache?
        
        init(model: LoginResultModel, cache: SessionCache?) {
            self.model = model
            self.cache = cache
        }
        
        /// Store the response **if valid** in the user's keychain.
        /// You can save the returned value safely in your `UserDefaults`, or your database
        /// and then retrieve the `SessionCache` when needed.
        /// - Returns: The `key` used to store `SessionCache` in your keychahin (the logged user's `pk`). `nil` otherwise.
        public func persist() -> String? {
            let encoder = JSONEncoder()
            
            guard model == .success,
                let cache = cache,
                let dsUserId = cache.storage?.dsUserId,
                !dsUserId.isEmpty,
                let data = try? encoder.encode(cache) else { return nil }
            // update keychain.
            let keychain = KeychainSwift()
            keychain.set(data, forKey: dsUserId)
            return dsUserId
        }
    }
}
public extension SessionCache {
    /// Init a `SessionCache` with the data stored in the user's keychain
    /// and persisted through `Login.Response.persist()`.
    /// - Parameters:
    ///     - key:  The `String` returned by `Login.Response.persist()`
    /// - Returns: The `SessionCache` if valid `Data` is found in the keychain, `nil` otherwise.
    static func persisted(with key: String) -> SessionCache? {
        let keychain = KeychainSwift()
        let decoder = JSONDecoder()
        guard let data = keychain.getData(key) else { return nil }
        // decode and return.
        return try? decoder.decode(SessionCache.self, from: data)
    }
}

/// The generic `Handler` interface. Should not be used directly.
public class Handler {
    weak var handler: APIHandler!
    init(handler: APIHandler) { self.handler = handler }
    
    /// The requests helper.
    var requests: HttpHelper { return handler.requests }
    /// The pagination helper.
    var pages: PaginationHelper { return handler.pages }
}
