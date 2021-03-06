//
//  HttpServer.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//


#if os(Linux)
    import Glibc
#else
    import Foundation
#endif

public class HttpServerIO {
    
    private var listenSocket: Socket = Socket(socketFileDescriptor: -1)
    private var clientSockets: Set<Socket> = []
    private let clientSocketsLock = Lock()
    
    @available(OSX 10.10, *)
    public func start(_ listenPort: in_port_t = 8080, forceIPv4: Bool = false) throws {
        stop()
        listenSocket = try Socket.tcpSocketForListen(listenPort, forceIPv4: forceIPv4)
        DispatchQueue.global(attributes: DispatchQueue.GlobalAttributes.qosBackground).async {
            while let socket = try? self.listenSocket.acceptClientSocket() {
                self.lock(self.clientSocketsLock) {
                    self.clientSockets.insert(socket)
                }
                DispatchQueue.global(attributes: DispatchQueue.GlobalAttributes.qosBackground).async {
                    self.handleConnection(socket)
                    self.lock(self.clientSocketsLock) {
                        self.clientSockets.remove(socket)
                    }
                }
            }
            self.stop()
        }
    }
    
    public func stop() {
        listenSocket.release()
        lock(self.clientSocketsLock) {
            for socket in self.clientSockets {
                socket.shutdwn()
            }
            self.clientSockets.removeAll(keepingCapacity: true)
        }
    }
    
    public func dispatch(_ request: HttpRequest) -> ([String: String], (HttpRequest) -> HttpResponse) {
        return ([:], { _ in HttpResponse.NotFound })
    }
    
    private func handleConnection(_ socket: Socket) {
        let address = try? socket.peername()
        let parser = HttpParser()
        while let request = try? parser.readHttpRequest(socket) {
            let request = request
            let (params, handler) = self.dispatch(request)
            request.address = address
            request.params = params;
            let response = handler(request)
            var keepConnection = parser.supportsKeepAlive(request.headers)
            do {
                keepConnection = try self.respond(socket, response: response, keepAlive: keepConnection)
            } catch {
                print("Failed to send response: \(error)")
                break
            }
            if let session = response.socketSession() {
                session(socket)
                break
            }
            if !keepConnection { break }
        }
        socket.release()
    }
    
    private func lock(_ handle: Lock, closure: () -> ()) {
        handle.lock()
        closure()
        handle.unlock();
    }
    
    private struct InnerWriteContext: HttpResponseBodyWriter {
        let socket: Socket
        
        func write(_ file: File) {
            var offset: off_t = 0
            
            let _ = sendfile(fileno(file.pointer), socket.socketFileDescriptor, 0, &offset, nil, 0)
        }
        
        func write(_ data: [UInt8]) {
            write(ArraySlice(data))
        }
        
        func write(_ data: ArraySlice<UInt8>) {
            do {
                try socket.writeUInt8(data)
            } catch {
                print("\(error)")
            }
        }
    }
    
    private func respond(_ socket: Socket, response: HttpResponse, keepAlive: Bool) throws -> Bool {
        try socket.writeUTF8("HTTP/1.1 \(response.statusCode()) \(response.reasonPhrase())\r\n")
        
        let content = response.content()
        
        if content.length >= 0 {
            try socket.writeUTF8("Content-Length: \(content.length)\r\n")
        }
        
        if keepAlive && content.length != -1 {
            try socket.writeUTF8("Connection: keep-alive\r\n")
        }
        
        for (name, value) in response.headers() {
            try socket.writeUTF8("\(name): \(value)\r\n")
        }
        
        try socket.writeUTF8("\r\n")
    
        if let writeClosure = content.write {
            let context = InnerWriteContext(socket: socket)
            try writeClosure(context)
        }
        
        return keepAlive && content.length != -1;
    }
}

#if os(Linux)
    
import Glibc
    
struct sf_hdtr { }
    
// Linux supports sendfile (http://man7.org/linux/man-pages/man2/sendfile.2.html)
// but it's not exposed by the module map from the Swift toolchain.
//
// TODO - use @_silgen_name to get the sendfile entry point.
    
func sendfile(_ source: Int32, _ target: Int32, _: off_t, _: UnsafeMutablePointer<off_t>!, _: UnsafeMutablePointer<sf_hdtr>!, _: Int32) -> Int32 {
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let readResult = read(source, &buffer, buffer.count)
        guard readResult > 0 else {
            return Int32(readResult)
        }
        var writeCounter = 0
        while writeCounter < readResult {
            let writeResult = write(target, &buffer + writeCounter, readResult - writeCounter)
            guard writeResult > 0 else {
                return Int32(writeResult)
            }
            writeCounter = writeCounter + writeResult
        }
    }
}

public class Lock {

    private var mutex = pthread_mutex_t()
    
    init() { pthread_mutex_init(&mutex, nil) }
    
    public func lock() { pthread_mutex_lock(&mutex) }
    
    public func unlock() { pthread_mutex_unlock(&mutex) }
    
    deinit { pthread_mutex_destroy(&mutex) }
}

public class DispatchQueue {
    
    private static let instance = DispatchQueue()
    
    public struct GlobalAttributes {
        public static let qosBackground: DispatchQueue.GlobalAttributes = GlobalAttributes()
    }
    
    public class func global(attributes: DispatchQueue.GlobalAttributes) -> DispatchQueue {
        return instance
    }
    
    private class DispatchContext {
        let block: ((Void) -> Void)
        init(_ block: ((Void) -> Void)) {
            self.block = block
        }
    }
    
    public func async(execute work: @convention(block) () -> Swift.Void) {
        let context = UnsafeMutablePointer<Void>(OpaquePointer(bitPattern: Unmanaged.passRetained(DispatchContext(work))))
        var pthread: pthread_t = 0
        pthread_create(&pthread, nil, { (context: UnsafeMutablePointer<Swift.Void>?) -> UnsafeMutablePointer<Swift.Void>? in
	    if let context = context {
                let unmanaged = Unmanaged<DispatchContext>.fromOpaque(OpaquePointer(context))
                unmanaged.takeUnretainedValue().block()
                unmanaged.release()
            }
            return nil
        }, context)
    }
}

#endif
