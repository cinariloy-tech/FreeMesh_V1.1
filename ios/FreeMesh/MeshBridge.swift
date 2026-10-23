import Foundation
import CoreBluetooth
import WebKit

// ESP32 düğümüne BLE ile bağlanır. Android'deki FreeMeshBle.java'nın iOS karşılığı.
// Protokol: Nordic UART benzeri servis. Telefon RX'e yazar, düğüm TX'ten bildirir.
// Her mesaj JSON satırı, \n ile biter.
final class MeshBridge: NSObject, WKScriptMessageHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = MeshBridge()

    static let svc = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    // Web tarafında window.FMBridge olarak görünür
    static let injectedJS = """
    window.FMBridge = {
      send: function (s) { window.webkit.messageHandlers.fm.postMessage(s); },
      connected: function () { return window.__fmReady === true; }
    };
    """

    weak var webView: WKWebView?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var isReady = false
    private var inBuf = Data()
    private var pending: [Data] = []

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Web -> telefon -> düğüm
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let s = message.body as? String else { return }
        send(s)
    }

    private func send(_ json: String) {
        guard isReady, let p = peripheral, let rx = rxChar else { return }
        let bytes = Array((json + "\n").utf8)
        let size = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        var i = 0
        while i < bytes.count {
            let end = min(i + size, bytes.count)
            pending.append(Data(bytes[i..<end]))
            i = end
        }
        flush(p, rx)
    }

    private func flush(_ p: CBPeripheral, _ rx: CBCharacteristic) {
        while !pending.isEmpty && p.canSendWriteWithoutResponse {
            p.writeValue(pending.removeFirst(), for: rx, type: .withoutResponse)
        }
    }

    // MARK: Düğüm -> telefon -> web
    private func consume(_ data: Data) {
        inBuf.append(data)
        while let idx = inBuf.firstIndex(of: 0x0A) {
            let lineData = inBuf.subdata(in: inBuf.startIndex..<idx)
            inBuf.removeSubrange(inBuf.startIndex...idx)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { deliver(line) }
        }
    }

    private func deliver(_ line: String) {
        // Satırı güvenli bir JS string literal'ına çevirmek için JSON dizisi kullanılır
        guard let enc = try? JSONSerialization.data(withJSONObject: [line]),
              let arr = String(data: enc, encoding: .utf8) else { return }
        let literal = String(arr.dropFirst().dropLast())
        eval("window.onMeshRx && window.onMeshRx(\(literal))")
    }

    private func setStatus(_ s: String) {
        eval("window.onBleState && window.onBleState('\(s)')")
    }

    private func setReady(_ r: Bool) {
        eval("window.__fmReady = \(r ? "true" : "false")")
    }

    private func eval(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Tarama ve bağlantı
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: startScan()
        case .poweredOff: setStatus("bt_off")
        default: break
        }
    }

    private func startScan() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        setStatus("scanning")
        central.scanForPeripherals(withServices: [MeshBridge.svc], options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        setStatus("connecting")
        central.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([MeshBridge.svc])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        reset(retry: true)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        reset(retry: true)
    }

    private func reset(retry: Bool) {
        isReady = false
        rxChar = nil
        peripheral = nil
        pending.removeAll()
        inBuf.removeAll()
        setReady(false)
        setStatus("disconnected")
        if retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startScan() }
        }
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == MeshBridge.svc }) else {
            central.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics([MeshBridge.rxUUID, MeshBridge.txUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let chars = s.characteristics else { return }
        rxChar = chars.first { $0.uuid == MeshBridge.rxUUID }
        if let tx = chars.first(where: { $0.uuid == MeshBridge.txUUID }) {
            p.setNotifyValue(true, for: tx)
        } else {
            central.cancelPeripheralConnection(p)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == MeshBridge.txUUID, ch.isNotifying else { return }
        isReady = true
        setReady(true)
        setStatus("connected")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == MeshBridge.txUUID, let d = ch.value { consume(d) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        if let rx = rxChar { flush(p, rx) }
    }
}
