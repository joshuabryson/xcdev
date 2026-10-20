import Foundation
import Synchronization

/// The direct route: CoreSimulator's service lookup and libxpc's simulator endpoint,
/// resolved by name at run time, so a macOS or Xcode that lacks a piece degrades to a named failure.
public struct VendorEventRoute: PostureRoute {
    public let id = PostureRouteID.direct

    public init() { /* stateless */ }

    public func availability(_ ctx: PostureContext) -> RouteAvailability {
        do {
            _ = try PrivateSymbols.load()
            return .available
        } catch {
            return .unavailable("\(error)")
        }
    }

    /// Connects, sends, waits for the barrier, then runs `witness` with the connection still open.
    public func apply<Result: Sendable>(_ request: PostureRequest, _ ctx: PostureContext,
                                        holdingUntil witness: () async throws -> Result) async throws -> Result {
        let message = try VendorEventMessage.build(request, ctx.recipe)
        let connection = try VendorEventConnection(udid: ctx.udid, developerDir: ctx.developerDir, feature: ctx.recipe.feature)
        defer { connection.close() }
        try await connection.send(message)
        return try await witness()
    }
}

/// The private pieces, each looked up by name. A missing one names itself.
struct PrivateSymbols {
    typealias EndpointFromPort = @convention(c) (mach_port_t) -> xpc_endpoint_t
    typealias EnableSim2Host = @convention(c) (xpc_connection_t) -> Void

    let objcMsgSend: UnsafeMutableRawPointer
    let endpointFromPort: EndpointFromPort
    let enableSim2Host: EnableSim2Host

    static let coreSimulator = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"

    static func load() throws -> PrivateSymbols {
        guard dlopen(coreSimulator, RTLD_NOW) != nil else {
            throw VendorEventError(step: "load CoreSimulator", detail: dlerror().map { String(cString: $0) } ?? "dlopen failed")
        }
        return PrivateSymbols(
            objcMsgSend: try symbol("objc_msgSend"),
            endpointFromPort: unsafeBitCast(try symbol("xpc_endpoint_create_mach_port_4sim"), to: EndpointFromPort.self),
            enableSim2Host: unsafeBitCast(try symbol("xpc_connection_enable_sim2host_4sim"), to: EnableSim2Host.self))
    }

    /// `dlsym` in every loaded image (`RTLD_DEFAULT`, which Swift does not import, is `(void *) -2`).
    static func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            throw VendorEventError(step: "libxpc", detail: "\(name) is missing on this macOS; this needs an xcd change")
        }
        return pointer
    }
}

/// One connection to a clone's HID bridge daemon. Lives in one task; `close` cancels it.
final class VendorEventConnection {
    typealias MsgSend1 = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Unmanaged<AnyObject>?
    typealias MsgSend0 = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Unmanaged<AnyObject>?
    typealias MsgSendGet = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    typealias MsgSendPort = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> mach_port_t

    /// A reference to the last event's text, so the `@Sendable` event handler shares it without capturing `self`.
    private final class LastEvent: Sendable { let text = Mutex<String?>(nil) }

    private let connection: xpc_connection_t
    /// The last event the daemon's side sent, for a failure's details; the daemon sends no replies, only errors.
    private let lastEvent = LastEvent()

    init(udid: String, developerDir: String, feature: String) throws {
        let symbols = try PrivateSymbols.load()
        let device = try Self.device(udid: udid, developerDir: developerDir, msgSend: symbols.objcMsgSend)
        let port = try Self.servicePort(device, feature: feature, msgSend: symbols.objcMsgSend)
        connection = xpc_connection_create_from_endpoint(symbols.endpointFromPort(port))
        symbols.enableSim2Host(connection)
        let events = lastEvent
        xpc_connection_set_event_handler(connection) { event in
            let text = xpc_copy_description(event)
            events.text.withLock { $0 = String(cString: text) }
            free(text)
        }
        xpc_connection_resume(connection)
    }

    /// CoreSimulator's `SimDevice` for the clone, from the default set, where every xcd clone lives.
    private static func device(udid: String, developerDir: String, msgSend: UnsafeMutableRawPointer) throws -> AnyObject {
        guard let contextClass: AnyClass = NSClassFromString("SimServiceContext") else {
            throw VendorEventError(step: "SimServiceContext", detail: "the class is not in CoreSimulator; this needs an xcd change")
        }
        var error: Unmanaged<NSError>?
        let shared = unsafeBitCast(msgSend, to: MsgSend1.self)
        guard let context = shared(contextClass, NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"),
                                   developerDir as NSString, &error)?.takeUnretainedValue() else {
            throw VendorEventError(step: "service context", detail: text(error))
        }
        let defaultSet = unsafeBitCast(msgSend, to: MsgSend0.self)
        guard let set = defaultSet(context, NSSelectorFromString("defaultDeviceSetWithError:"), &error)?.takeUnretainedValue() else {
            throw VendorEventError(step: "default device set", detail: text(error))
        }
        let get = unsafeBitCast(msgSend, to: MsgSendGet.self)
        guard let byUDID = get(set, NSSelectorFromString("devicesByUDID"))?.takeUnretainedValue() as? [UUID: AnyObject],
              let uuid = UUID(uuidString: udid), let device = byUDID[uuid] else {
            throw VendorEventError(step: "device", detail: "\(udid) is not in the default device set")
        }
        return device
    }

    /// The mach port of the daemon's vendor-event service inside the clone.
    private static func servicePort(_ device: AnyObject, feature: String, msgSend: UnsafeMutableRawPointer) throws -> mach_port_t {
        var error: Unmanaged<NSError>?
        let lookup = unsafeBitCast(msgSend, to: MsgSendPort.self)
        let port = lookup(device, NSSelectorFromString("lookup:error:"), feature as NSString, &error)
        guard port != 0 else {
            throw VendorEventError(step: "lookup \(feature)", detail: error == nil ? "no port; is the clone booted?" : text(error))
        }
        return port
    }

    private static func text(_ error: Unmanaged<NSError>?) -> String {
        error?.takeUnretainedValue().localizedDescription ?? "no error given"
    }

    /// Sends, then waits up to 3 s for the barrier, which proves only that the message left xcd.
    func send(_ message: xpc_object_t) async throws {
        xpc_connection_send_message(connection, message)
        let barrier = Signal()
        xpc_connection_send_barrier(connection) { barrier.fire() }
        guard await barrier.wait(timeout: .seconds(3)) else {
            throw VendorEventError(step: "barrier", detail: lastEvent.text.withLock { $0 } ?? "the daemon did not take the message within 3 s")
        }
    }

    func close() { xpc_connection_cancel(connection) }
}

/// A one-shot flag an XPC callback fires and an async caller awaits with a timeout, without blocking a thread.
final class Signal: Sendable {
    private struct State {
        var fired = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func fire() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.fired = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// True when fired within `timeout`.
    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.suspendUntilFired(); return true }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Suspends until `fire`, or until cancelled, which fires it so no continuation is left waiting.
    private func suspendUntilFired() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyFired = state.withLock { state -> Bool in
                    if state.fired { return true }
                    state.waiter = continuation
                    return false
                }
                if alreadyFired { continuation.resume() }
            }
        } onCancel: { fire() }
    }
}
