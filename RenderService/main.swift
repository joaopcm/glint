import Foundation

let delegate = RenderServiceListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
