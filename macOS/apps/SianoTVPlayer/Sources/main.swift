import AppKit
import AVKit
import Foundation

private extension NSToolbarItem.Identifier {
    static let visionemScan = NSToolbarItem.Identifier("visionem.scan")
    static let visionemStop = NSToolbarItem.Identifier("visionem.stop")
    static let visionemPIP = NSToolbarItem.Identifier("visionem.pip")
    static let visionemStatus = NSToolbarItem.Identifier("visionem.status")
}

struct TVChannel: Codable, Hashable, Sendable {
    let number: Int
    let band: String
    let frequency: Int
    var name: String?
    var rfLocked: Bool?
    var demodLocked: Bool?
    var scanStatus: String?
    var title: String {
        guard let name, !name.isEmpty else { return "Canal \(number)" }
        return name
    }
    var subtitle: String {
        if number <= 0 {
            return "Transmissao detectada - \(band)"
        }
        let prefix = (number > 0 && name != nil && name?.isEmpty == false) ? "Canal \(number) - " : ""
        let base = "\(prefix)\(band) - \(frequency) Hz"
        guard let rfLocked, let demodLocked else { return base }
        if demodLocked { return "\(base) - pronto para imagem" }
        if rfLocked { return "\(base) - portadora sem demod" }
        return "\(base) - sem lock"
    }
}

struct TransmissionProbe: Sendable {
    let serviceNames: [String]
    let hasVideo: Bool
    let bytes: Int
}

enum TransmissionProbeResult: Sendable {
    case found(TransmissionProbe)
    case unavailable(String)
    case none
}

enum ReceiverState: String {
    case idle = "Pronto"
    case probing = "Procurando TS ativo"
    case scanning = "Varrendo canais"
    case watching = "Sintonizando"
    case streaming = "Recebendo transmissao"
    case deviceBusy = "Dispositivo ocupado"
    case noSignal = "Sem transmissao"
    case disconnected = "Receptor desconectado"
    case error = "Falha"
}

private let minimumPreviewBytes = 160 * 1024
private let minimumHLSStartBytes = 1400 * 1024
private let minimumTSQualityBytes = 256 * 1024
private let fallbackAppVersion = "1.10.2"

@MainActor
final class SianoController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    private let window: NSWindow
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Selecione um canal para assistir")
    private let detailLabel = NSTextField(labelWithString: "Visionem DTV - ISDB-Tb Brasil")
    private let diagnosticsLabel = NSTextField(labelWithString: "USB: aguardando | TS: 0 bytes | Estado: pronto")
    private let usbIndicatorDot = NSView()
    private let usbIndicatorLabel = NSTextField(labelWithString: "Receptor USB: verificando")
    private let playerView = AVPlayerView()
    private let frameView = NSImageView()
    private var scanToolbarItem: NSToolbarItem?
    private var pipWindow: NSPanel?
    private let pipImageView = NSImageView()
    private var channels: [TVChannel] = []
    private var scanProcess: Process?
    private var watchProcess: Process?
    private var watchOutputPipe: Pipe?
    private var currentOutputURL: URL?
    private var playbackTimer: Timer?
    private var frameTimer: Timer?
    private var hlsPlaybackTimer: Timer?
    private var playerReadinessTimer: Timer?
    private var didRunTSQualityCheck = false
    private var tsQualitySummary: String?
    private var hlsProcess: Process?
    private var hlsDirectoryURL: URL?
    private var hlsPlaylistURL: URL?
    private var audioProcess: Process?
    private var mjpegBuffer = Data()
    private var framePreviewStartedAt: Date?
    private var isExtractingFrame = false
    private var receiverState: ReceiverState = .idle
    private var isReceiverConnected = false
    private var appTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Visionem DTV - \(version ?? fallbackAppVersion)"
    }

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
        loadChannels()
        refreshUSBIndicator()
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func configureWindow() {
        window.title = appTitle
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 960, height: 560)
        configureToolbar()

        let root = NSSplitView()
        root.isVertical = true
        root.dividerStyle = .thin
        root.translatesAutoresizingMaskIntoConstraints = false

        let videoPane = NSView()
        let sidebarEffect = NSVisualEffectView()
        let sidebar = NSView()
        videoPane.wantsLayer = true
        videoPane.layer?.backgroundColor = NSColor.black.cgColor
        sidebarEffect.material = .sidebar
        sidebarEffect.blendingMode = .behindWindow
        sidebarEffect.state = .active
        sidebarEffect.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(videoPane)
        root.addArrangedSubview(sidebarEffect)
        sidebarEffect.addSubview(sidebar)

        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        frameView.imageScaling = .scaleProportionallyUpOrDown
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.black.cgColor
        frameView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = NSColor(white: 0.78, alpha: 1)
        detailLabel.alignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        videoPane.addSubview(playerView)
        videoPane.addSubview(frameView)
        videoPane.addSubview(statusLabel)
        videoPane.addSubview(detailLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.delegate = self
        tableView.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel"))
        column.resizingMask = .autoresizingMask
        column.width = 320
        column.minWidth = 260
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        let title = NSTextField(labelWithString: appTitle)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "TV digital brasileira")
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsLabel.textColor = .secondaryLabelColor
        diagnosticsLabel.lineBreakMode = .byWordWrapping
        diagnosticsLabel.maximumNumberOfLines = 3
        diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false
        usbIndicatorDot.wantsLayer = true
        usbIndicatorDot.layer?.cornerRadius = 4.5
        usbIndicatorDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        usbIndicatorDot.translatesAutoresizingMaskIntoConstraints = false
        usbIndicatorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        usbIndicatorLabel.textColor = .secondaryLabelColor
        usbIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false

        let usbIndicatorStack = NSStackView(views: [usbIndicatorDot, usbIndicatorLabel])
        usbIndicatorStack.orientation = .horizontal
        usbIndicatorStack.alignment = .centerY
        usbIndicatorStack.spacing = 7
        usbIndicatorStack.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(title)
        sidebar.addSubview(subtitle)
        sidebar.addSubview(usbIndicatorStack)
        sidebar.addSubview(diagnosticsLabel)
        sidebar.addSubview(scrollView)

        window.contentView = NSView()
        window.contentView?.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),

            videoPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 620),
            sidebarEffect.widthAnchor.constraint(equalToConstant: 336),

            sidebar.leadingAnchor.constraint(equalTo: sidebarEffect.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: sidebarEffect.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sidebarEffect.bottomAnchor),

            playerView.leadingAnchor.constraint(equalTo: videoPane.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: videoPane.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: videoPane.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: videoPane.bottomAnchor),

            frameView.leadingAnchor.constraint(equalTo: videoPane.leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: videoPane.trailingAnchor),
            frameView.topAnchor.constraint(equalTo: videoPane.topAnchor),
            frameView.bottomAnchor.constraint(equalTo: videoPane.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: videoPane.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: videoPane.centerYAnchor, constant: -16),
            detailLabel.centerXAnchor.constraint(equalTo: videoPane.centerXAnchor),
            detailLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),

            title.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            usbIndicatorDot.widthAnchor.constraint(equalToConstant: 9),
            usbIndicatorDot.heightAnchor.constraint(equalToConstant: 9),
            usbIndicatorStack.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            usbIndicatorStack.trailingAnchor.constraint(lessThanOrEqualTo: title.trailingAnchor),
            usbIndicatorStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 10),
            diagnosticsLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            diagnosticsLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            diagnosticsLabel.topAnchor.constraint(equalTo: usbIndicatorStack.bottomAnchor, constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: diagnosticsLabel.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "VisionemDTVToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.visionemScan, .visionemStop, .flexibleSpace, .visionemStatus, .visionemPIP]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.visionemScan, .visionemStop, .flexibleSpace, .visionemStatus, .visionemPIP]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .visionemScan:
            item.label = "Buscar"
            item.paletteLabel = "Buscar"
            item.toolTip = "Buscar transmissoes brasileiras"
            item.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "Buscar")
            item.target = self
            item.action = #selector(refreshChannels)
            scanToolbarItem = item
        case .visionemStop:
            item.label = "Parar"
            item.paletteLabel = "Parar"
            item.toolTip = "Parar recepcao"
            item.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Parar")
            item.target = self
            item.action = #selector(stopWatching)
        case .visionemPIP:
            item.label = "PIP"
            item.paletteLabel = "PIP"
            item.toolTip = "Abrir picture in picture"
            item.image = NSImage(systemSymbolName: "pip.enter", accessibilityDescription: "PIP")
            item.target = self
            item.action = #selector(togglePIP)
        case .visionemStatus:
            let label = NSTextField(labelWithString: "ISDB-Tb Brasil")
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            item.view = label
        default:
            return nil
        }
        return item
    }

    private func loadChannels() {
        setState(.idle, "Carregando canais salvos...", "Visionem DTV - ISDB-Tb Brasil")
        channels = loadSavedChannels()
        tableView.reloadData()
        if channels.isEmpty {
            setState(.probing, "Nenhum canal salvo", "Primeira execucao; iniciando busca brasileira")
            startScan()
        } else {
            setState(.idle, "Selecione um canal", "\(channels.count) canais salvos")
        }
    }

    @objc private func refreshChannels() {
        refreshUSBIndicator()
        stopWatching()
        clearChannelListForFreshScan()
        startScan()
    }

    private func clearChannelListForFreshScan() {
        channels.removeAll()
        tableView.reloadData()
        if let url = channelsStoreURL() {
            try? FileManager.default.removeItem(at: url)
        }
        statusLabel.isHidden = false
        detailLabel.isHidden = false
        setState(.probing, "Limpando lista...", "A busca sera executada do zero")
    }

    @objc func stopWatching() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        hlsPlaybackTimer?.invalidate()
        hlsPlaybackTimer = nil
        stopExternalAudioPlayback()
        isExtractingFrame = false
        scanProcess?.terminate()
        scanProcess = nil
        watchOutputPipe?.fileHandleForReading.readabilityHandler = nil
        watchOutputPipe = nil
        if let process = watchProcess {
            Self.terminateProcessTree(process.processIdentifier)
            process.terminate()
        }
        watchProcess = nil
        stopHLSPlayback()
        playerReadinessTimer?.invalidate()
        playerReadinessTimer = nil
        didRunTSQualityCheck = false
        tsQualitySummary = nil
        stopExternalAudioPlayback()
        currentOutputURL = nil
        playerView.player?.pause()
        playerView.player = nil
        frameView.image = nil
        pipImageView.image = nil
        statusLabel.isHidden = false
        detailLabel.isHidden = false
        refreshUSBIndicator()
        setState(.idle, "Parado", "Selecione um canal para assistir")
    }

    private func startScan() {
        refreshUSBIndicator()
        guard let binary = findSianoTVBinary() else {
            statusLabel.stringValue = "siano-tv nao encontrado"
            detailLabel.stringValue = "Instale o pacote antes de atualizar"
            return
        }

        channels = channels.map {
            TVChannel(number: $0.number, band: $0.band, frequency: $0.frequency, name: $0.name, rfLocked: nil, demodLocked: nil, scanStatus: "aguardando")
        }
        tableView.reloadData()
        setSearchEnabled(false)
        setState(.probing, "Procurando transmissao ativa...", "Primeiro teste: MPEG-TS ja entregue pelo firmware")

        DispatchQueue.global(qos: .userInitiated).async {
            switch Self.detectCurrentTransmission(binary: binary, probeSeconds: 20) {
            case .found(let activeTransmission) where activeTransmission.hasVideo:
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.channels.removeAll()
                    for (index, serviceName) in activeTransmission.serviceNames.enumerated() {
                        self.applyScanResult(Self.currentStreamPlaceholder(name: serviceName, index: index))
                    }
                    self.setSearchEnabled(true)
                    self.persistChannels()
                    let suffix = self.channels.count == 1 ? "servico detectado" : "servicos detectados"
                    self.setState(.streaming, "Transmissao ativa encontrada", "\(self.channels.count) \(suffix) no fluxo atual")
                    self.updateDiagnostics(bytes: activeTransmission.bytes, note: "TS ativo")
                    self.autoStartCurrentStreamIfAvailable()
                }
                return
            case .unavailable(let message):
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.setSearchEnabled(true)
                    self.setUnavailableState(message)
                }
                return
            case .found, .none:
                break
            }

            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["scan-br-smart"]
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                DispatchQueue.main.async {
                    self.scanProcess = process
                    self.setState(.scanning, "Varrendo canais brasileiros...", "Executando scan-br-smart")
                }
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                let scanned = Self.detectConfirmedPhysicalChannels(binary: binary, scanText: text)
                let currentTransmission = Self.detectCurrentTransmission(binary: binary, probeSeconds: 12)
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.channels.removeAll()
                    for channel in scanned {
                        self.applyScanResult(channel)
                    }
                    if case .found(let currentTransmission) = currentTransmission, currentTransmission.hasVideo {
                        for (index, serviceName) in currentTransmission.serviceNames.enumerated() {
                            self.applyScanResult(Self.currentStreamPlaceholder(name: serviceName, index: index))
                        }
                    }
                    self.setSearchEnabled(true)
                    self.persistChannels()
                    if case .unavailable(let message) = currentTransmission {
                        self.setUnavailableState(message)
                    } else if self.channels.isEmpty {
                        self.setState(.noSignal, "Nenhuma transmissao encontrada", "A busca so lista canais com TS, video e nome de servico confirmados")
                    } else {
                        let suffix = self.channels.count == 1 ? "transmissao encontrada" : "transmissoes encontradas"
                        self.setState(.idle, "Busca concluida", "\(self.channels.count) \(suffix)")
                    }
                    self.autoStartCurrentStreamIfAvailable()
                }
            } catch {
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.setSearchEnabled(true)
                    self.setState(.error, "Falha ao atualizar", error.localizedDescription)
                }
            }
        }
    }

    private func setSearchEnabled(_ enabled: Bool) {
        scanToolbarItem?.isEnabled = enabled
    }

    private func setState(_ state: ReceiverState, _ status: String, _ detail: String) {
        receiverState = state
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        updateDiagnostics(note: detail)
    }

    private func setUnavailableState(_ message: String) {
        let lowercased = message.lowercased()
        if lowercased.contains("ocupado") || lowercased.contains("libusb_error_access") {
            setState(.deviceBusy, "Dispositivo ocupado", message)
        } else if Self.indicatesUnresponsiveReceiver(message) {
            setState(.error, "Receptor sem resposta", message)
        } else if lowercased.contains("nao encontrado") ||
                    lowercased.contains("não encontrado") ||
                    lowercased.contains("desconectado") ||
                    lowercased.contains("not found") ||
                    lowercased.contains("not openable") ||
                    lowercased.contains("mdtv=0") {
            setState(.disconnected, "Receptor USB nao detectado", message)
            setUSBIndicator(connected: false, detail: "desconectado")
        } else {
            setState(.error, "Falha ao verificar receptor", message)
        }
    }

    private func updateDiagnostics(bytes: Int? = nil, note: String? = nil) {
        let byteText = bytes.map { "\($0) bytes" } ?? "0 bytes"
        let usbText = isReceiverConnected ? "conectado" : "desconectado"
        let qualityText = tsQualitySummary.map { " | \($0)" } ?? ""
        diagnosticsLabel.stringValue = "USB: \(usbText) | TS: \(byteText) | Estado: \(receiverState.rawValue)\(note.map { " | \($0)" } ?? "")\(qualityText)"
    }

    private func refreshUSBIndicator() {
        guard let binary = findSianoTVBinary() else {
            setUSBIndicator(connected: false, detail: "siano-tv indisponivel")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["usb-state"]
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.setUSBIndicator(connected: false, detail: "falha ao verificar")
                }
                return
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let connected = text.contains("summary: mdtv=1") || text.contains("mdtv: present")
            DispatchQueue.main.async {
                self.setUSBIndicator(connected: connected, detail: connected ? "conectado" : "desconectado")
            }
        }
    }

    private func setUSBIndicator(connected: Bool, detail: String) {
        isReceiverConnected = connected
        usbIndicatorDot.layer?.backgroundColor = (connected ? NSColor.systemGreen : NSColor.systemRed).cgColor
        usbIndicatorLabel.stringValue = connected ? "Receptor USB conectado" : "Receptor USB \(detail)"
        updateDiagnostics(note: detailLabel.stringValue)
    }

    private func autoStartCurrentStreamIfAvailable() {
        guard let index = channels.firstIndex(where: { $0.number == 0 }) else { return }
        if tableView.selectedRow != index {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            startWatching(channels[index])
        }
        tableView.scrollRowToVisible(index)
    }

    @objc private func togglePIP() {
        if let pipWindow, pipWindow.isVisible {
            pipWindow.orderOut(nil)
            return
        }
        let panel = pipWindow ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Visionem DTV PIP"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pipImageView.imageScaling = .scaleProportionallyUpOrDown
        pipImageView.wantsLayer = true
        pipImageView.layer?.backgroundColor = NSColor.black.cgColor
        panel.contentView = pipImageView
        pipWindow = panel
        panel.center()
        panel.orderFrontRegardless()
    }

    private func applyScanResult(_ scanned: TVChannel) {
        var updated = scanned
        if let index = channels.firstIndex(where: { $0.number == scanned.number }) {
            updated.name = channels[index].name
            channels[index] = updated
        } else {
            channels.append(updated)
            sortChannels()
        }
        tableView.reloadData()
        persistChannels()
        setState(receiverState, "Canal \(updated.number): \(updated.scanStatus ?? "testado")", updated.subtitle)
    }

    private func startWatching(_ channel: TVChannel) {
        stopWatching()
        let outputURL = captureURL(for: channel.number)
        currentOutputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let binary = findSianoTVBinary() else {
            statusLabel.stringValue = "siano-tv nao encontrado"
            detailLabel.stringValue = "Instale o pacote ou compile o projeto antes de assistir"
            return
        }

        if isCurrentStreamChannel(channel) {
            runWatchProcess(binary: binary, arguments: ["dump-ts", "3600", "-"], outputURL: outputURL, channel: channel, isFallback: true)
        } else {
            let physicalChannel = physicalChannelNumber(for: channel)
            runWatchProcess(binary: binary, arguments: ["ts-probe-br", "\(physicalChannel)", "3600", "-"], outputURL: outputURL, channel: channel, isFallback: false)
        }
    }

    private func runWatchProcess(binary: String, arguments: [String], outputURL: URL, channel: TVChannel, isFallback: Bool) {
        guard let ffmpeg = Self.findExecutable(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]) else {
            setState(.error, "ffmpeg nao encontrado", "Instale ffmpeg para audio/video continuo")
            return
        }

        stopHLSPlayback()
        let hlsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionem-dtv-hls-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: hlsDir, withIntermediateDirectories: true)
        } catch {
            setState(.error, "Falha ao preparar HLS", error.localizedDescription)
            return
        }

        let playlistURL = hlsDir.appendingPathComponent("live.m3u8")
        let segmentPattern = hlsDir.appendingPathComponent("segment-%03d.ts").path
        let cliLogURL = hlsDir.appendingPathComponent("siano-tv.log")
        let ffmpegLogURL = hlsDir.appendingPathComponent("ffmpeg.log")
        let videoLogURL = hlsDir.appendingPathComponent("video-frames.log")
        FileManager.default.createFile(atPath: cliLogURL.path, contents: nil)
        FileManager.default.createFile(atPath: ffmpegLogURL.path, contents: nil)
        FileManager.default.createFile(atPath: videoLogURL.path, contents: nil)

        let sourceCommand = ([binary] + arguments).map(Self.shellQuote).joined(separator: " ")
        let command = [
            "set -o pipefail",
            "\(sourceCommand) 2>> \(Self.shellQuote(cliLogURL.path)) | /usr/bin/tee \(Self.shellQuote(outputURL.path)) | /usr/bin/tee >(\(Self.shellQuote(ffmpeg)) -hide_banner -loglevel warning -y -f mpegts -probesize 5000000 -analyzeduration 5000000 -fflags +genpts+discardcorrupt -err_detect ignore_err -i pipe:0 -map 0:v:0 -map 0:a:0 -c:v copy -c:a aac -b:a 96k -ar 48000 -ac 2 -f hls -hls_time 3 -hls_list_size 10 -hls_flags delete_segments+append_list+omit_endlist+independent_segments -hls_segment_filename \(Self.shellQuote(segmentPattern)) \(Self.shellQuote(playlistURL.path)) >> \(Self.shellQuote(ffmpegLogURL.path)) 2>&1) | \(Self.shellQuote(ffmpeg)) -hide_banner -loglevel warning -f mpegts -probesize 5000000 -analyzeduration 5000000 -fflags +genpts+discardcorrupt -err_detect ignore_err -i pipe:0 -map 0:v:0 -an -vf fps=15,scale=960:-2 -q:v 5 -f image2pipe -vcodec mjpeg pipe:1 2>> \(Self.shellQuote(videoLogURL.path))"
        ].joined(separator: "; ")

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe
        process.standardError = Pipe()
        watchProcess = process
        watchOutputPipe = pipe
        hlsDirectoryURL = hlsDir
        hlsPlaylistURL = playlistURL
        didRunTSQualityCheck = false
        tsQualitySummary = nil

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.appendMJPEGData(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.watchProcess === process else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size < 188 * 20 {
                    if !isFallback {
                        self.playbackTimer?.invalidate()
                        self.playbackTimer = nil
                        self.watchProcess = nil
                        try? FileManager.default.removeItem(at: outputURL)
                        self.runWatchProcess(binary: binary, arguments: ["dump-ts", "3600", "-"], outputURL: outputURL, channel: channel, isFallback: true)
                        return
                    }
                    let ffmpegTail = Self.tailText(ffmpegLogURL, maxBytes: 600)
                    let cliTail = Self.tailText(cliLogURL, maxBytes: 600)
                    self.setState(.noSignal, "Sem stream MPEG-TS", "CLI: \(cliTail) | ffmpeg: \(ffmpegTail)")
                }
            }
        }

        do {
            try process.run()
            setState(.watching, isFallback ? "Lendo stream MPEG-TS..." : "Sintonizando \(channel.title)...", isFallback ? outputURL.path : channel.subtitle)
            mjpegBuffer.removeAll(keepingCapacity: true)
            frameView.isHidden = false
            setState(.streaming, "Recebendo transmissao", "Video direto por frames MJPEG; audio por HLS")
            updateDiagnostics(note: "MJPEG + HLS preparando em \(hlsDir.path)")
            schedulePlaybackProbe(outputURL, channelNumber: channel.number, binary: binary, channel: channel, isFallback: isFallback)
        } catch {
            setState(.error, isFallback ? "Falha no fallback TS" : "Falha ao iniciar recepcao", error.localizedDescription)
        }
    }

    private func applyWatchOutput(_ text: String) {
        let lines = text.split(separator: "\n").map(String.init)
        guard let line = lines.last else { return }
        if line.contains("bytes=") {
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
            updateDiagnostics(note: detailLabel.stringValue)
        } else if line.contains("demod lock") {
            setState(.watching, "Sinal digital travado", line.trimmingCharacters(in: .whitespaces))
        } else if line.contains("final bytes") {
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        } else if line.contains("failed") {
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        }
    }

    private func appendMJPEGData(_ data: Data) {
        mjpegBuffer.append(data)
        while let start = Self.findJPEGStart(in: mjpegBuffer),
              let end = Self.findJPEGEnd(in: mjpegBuffer, after: start + 2) {
            if start > 0 {
                mjpegBuffer.removeSubrange(0..<start)
                continue
            }
            let frameEnd = end + 2
            let frameData = mjpegBuffer.subdata(in: 0..<frameEnd)
            mjpegBuffer.removeSubrange(0..<frameEnd)
            if let image = NSImage(data: frameData) {
                frameView.image = image
                pipImageView.image = image
                frameView.isHidden = false
                statusLabel.isHidden = true
                detailLabel.isHidden = true
            }
        }
        if mjpegBuffer.count > 2_000_000 {
            mjpegBuffer.removeAll(keepingCapacity: true)
        }
    }


    private func schedulePlaybackProbe(_ outputURL: URL, channelNumber: Int, binary: String, channel: TVChannel, isFallback: Bool) {
        let startedAt = Date()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > minimumPreviewBytes {
                    self.updateChannelNameFromTransportStream(outputURL, channelNumber: channelNumber)
                    let segmentCount = self.hlsDirectoryURL.map { Self.hlsSegmentCount(in: $0) } ?? 0
                    if !self.didRunTSQualityCheck && size > minimumTSQualityBytes {
                        self.didRunTSQualityCheck = true
                        self.runTSQualityCheck(binary: binary, outputURL: outputURL)
                    }
                    if let playlistURL = self.hlsPlaylistURL,
                       self.audioProcess == nil,
                       FileManager.default.fileExists(atPath: playlistURL.path),
                       segmentCount >= 2 {
                        self.startExternalHLSAudioPlayback(playlistURL)
                    }
                    self.updateDiagnostics(bytes: size, note: "video MJPEG ativo; audio segmentos=\(segmentCount)")
                } else {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    if !isFallback && elapsed >= 8 {
                        self.playbackTimer?.invalidate()
                        self.playbackTimer = nil
                        if let process = self.watchProcess {
                            Self.terminateProcessTree(process.processIdentifier)
                            process.terminate()
                        }
                        self.watchProcess = nil
                        try? FileManager.default.removeItem(at: outputURL)
                        self.setState(.watching, "Alternando para fluxo TS ativo...", "Retune sem TS apos \(Int(elapsed))s; usando dump-ts")
                        self.runWatchProcess(binary: binary, arguments: ["dump-ts", "3600", "-"], outputURL: outputURL, channel: channel, isFallback: true)
                        return
                    }
                    self.statusLabel.isHidden = false
                    self.detailLabel.isHidden = false
                    self.setState(.watching, "Aguardando video...", "Recebendo TS; aguardando pacotes de video suficientes")
                    self.updateDiagnostics(bytes: size)
                }
            }
        }
    }


    private func runTSQualityCheck(binary: String, outputURL: URL) {
        DispatchQueue.global(qos: .utility).async {
            let result = Self.runSianoTV(binary: binary, arguments: ["ts-quality", outputURL.path], timeout: 6)
            let summary = Self.summarizeTSQuality(result.output)
            DispatchQueue.main.async {
                self.tsQualitySummary = summary
                self.updateDiagnostics(note: "diagnostico TS atualizado")
            }
        }
    }

    nonisolated private static func summarizeTSQuality(_ text: String) -> String {
        var sync = "?"
        var continuity = "?"
        var video = "missing"
        var audio = "missing"
        var topMedia: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("sync_errors:") {
                sync = line.replacingOccurrences(of: "sync_errors:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("continuity_errors:") {
                continuity = line.replacingOccurrences(of: "continuity_errors:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("video_pid:") {
                video = line.replacingOccurrences(of: "video_pid:", with: "v").components(separatedBy: " ").prefix(3).joined(separator: " ")
            } else if line.hasPrefix("audio_pid:") {
                audio = line.replacingOccurrences(of: "audio_pid:", with: "a").components(separatedBy: " ").prefix(3).joined(separator: " ")
            } else if line.hasPrefix("pid 0x") && !line.contains("0x1fff") && topMedia.count < 2 {
                topMedia.append(line.replacingOccurrences(of: "pid ", with: ""))
            }
        }
        if video.contains("missing"), topMedia.count > 0 {
            video = "v? " + topMedia[0]
        }
        if audio.contains("missing"), topMedia.count > 1 {
            audio = "a? " + topMedia[1]
        }
        return "TS quality sync=\(sync) continuity=\(continuity) \(video) \(audio)"
    }

    private func startFramePreview(_ outputURL: URL) {
        frameTimer?.invalidate()
        framePreviewStartedAt = Date()
        frameView.isHidden = false
        renderFrame(from: outputURL)
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.renderFrame(from: outputURL)
            }
        }
    }

    private func startHLSPlayback(_ outputURL: URL) {
        stopHLSPlayback()
        guard let ffmpeg = Self.findExecutable(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]) else {
            detailLabel.stringValue = "ffmpeg nao encontrado para audio/video continuo"
            return
        }

        let hlsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionem-dtv-hls-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: hlsDir, withIntermediateDirectories: true)
        } catch {
            detailLabel.stringValue = "Falha ao preparar HLS: \(error.localizedDescription)"
            return
        }

        let playlistURL = hlsDir.appendingPathComponent("live.m3u8")
        let segmentPattern = hlsDir.appendingPathComponent("segment-%03d.ts").path
        let logURL = hlsDir.appendingPathComponent("ffmpeg.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let command = [
            "/usr/bin/tail -c +1 -f \(Self.shellQuote(outputURL.path))",
            "\(Self.shellQuote(ffmpeg)) -hide_banner -loglevel warning -y -f mpegts -probesize 5000000 -analyzeduration 5000000 -fflags +genpts+discardcorrupt -err_detect ignore_err -i pipe:0 -map 0:v:0 -map 0:a:0 -c:v copy -c:a aac -b:a 96k -ar 48000 -ac 2 -f hls -hls_time 3 -hls_list_size 10 -hls_flags delete_segments+append_list+omit_endlist+independent_segments -hls_segment_filename \(Self.shellQuote(segmentPattern)) \(Self.shellQuote(playlistURL.path))"
        ].joined(separator: " | ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = try? FileHandle(forWritingTo: logURL)
        process.standardError = process.standardOutput
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: hlsDir)
            detailLabel.stringValue = "Falha ao iniciar HLS: \(error.localizedDescription)"
            return
        }

        hlsProcess = process
        hlsDirectoryURL = hlsDir
        hlsPlaybackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            if FileManager.default.fileExists(atPath: playlistURL.path),
               Self.hlsSegmentCount(in: hlsDir) >= 2 {
                timer.invalidate()
                DispatchQueue.main.async {
                    self?.activateHLSPlayback(playlistURL)
                }
            }
        }
    }

    private func activateHLSPlayback(_ playlistURL: URL) {
        let item = AVPlayerItem(url: playlistURL)
        item.preferredForwardBufferDuration = 8
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = false
        player.volume = 1.0
        playerView.player = player
        player.play()
        startExternalHLSAudioPlayback(playlistURL)
        updateDiagnostics(note: "TS filtrado + HLS broadcast ativo")
        hlsPlaybackTimer = nil

        playerReadinessTimer?.invalidate()
        playerReadinessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let item else {
                    self.playerReadinessTimer?.invalidate()
                    self.playerReadinessTimer = nil
                    return
                }
                switch item.status {
                case .readyToPlay:
                    let hasVideoSize = item.presentationSize.width > 0 && item.presentationSize.height > 0
                    self.updateDiagnostics(note: "AVPlayer pronto video=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))")
                    if hasVideoSize {
                        self.frameTimer?.invalidate()
                        self.frameTimer = nil
                        self.frameView.isHidden = true
                        self.statusLabel.isHidden = true
                        self.detailLabel.isHidden = true
                        self.playerReadinessTimer?.invalidate()
                        self.playerReadinessTimer = nil
                    }
                case .failed:
                    let message = item.error?.localizedDescription ?? "erro desconhecido no AVPlayer"
                    self.updateDiagnostics(note: "AVPlayer falhou; mantendo preview: \(message)")
                    self.playerReadinessTimer?.invalidate()
                    self.playerReadinessTimer = nil
                case .unknown:
                    self.updateDiagnostics(note: "AVPlayer aguardando video; preview por frames mantido")
                @unknown default:
                    self.updateDiagnostics(note: "AVPlayer em estado desconhecido; preview mantido")
                }
            }
        }
    }


    private func startExternalHLSAudioPlayback(_ playlistURL: URL) {
        guard audioProcess == nil else { return }
        guard let ffplay = Self.findExecutable(["/opt/homebrew/bin/ffplay", "/usr/local/bin/ffplay"]) else {
            updateDiagnostics(note: "audio: AVPlayer somente; ffplay ausente")
            return
        }
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionem-dtv-hls-audio-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let command = "\(Self.shellQuote(ffplay)) -hide_banner -loglevel warning -nodisp -vn -volume 100 -fflags nobuffer -flags low_delay \(Self.shellQuote(playlistURL.path))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = try? FileHandle(forWritingTo: logURL)
        process.standardError = process.standardOutput
        process.terminationHandler = { [weak self] process in
            let logTail = Self.tailText(logURL, maxBytes: 500)
            DispatchQueue.main.async {
                guard let self, self.audioProcess === process else { return }
                self.audioProcess = nil
                if logTail.contains("CoreAudio error") || logTail.contains("audio open failed") {
                    self.updateDiagnostics(note: "CoreAudio sem saida valida; verifique Saida de Som")
                } else if !logTail.isEmpty {
                    self.updateDiagnostics(note: "audio externo encerrado: \(logTail)")
                }
            }
        }
        do {
            try process.run()
            audioProcess = process
            updateDiagnostics(note: "audio HLS externo ativo")
        } catch {
            updateDiagnostics(note: "falha audio HLS: \(error.localizedDescription)")
        }
    }

    private func stopExternalAudioPlayback() {
        if let process = audioProcess {
            Self.terminateProcessTree(process.processIdentifier)
            process.terminate()
        }
        audioProcess = nil
        Self.terminateMatchingProcesses(["visionem-dtv-hls-audio", "visionem-dtv-audio", "Movies/SianoTV/fluxo-", "ffplay -hide_banner -loglevel warning -nodisp -vn -volume 100"])
    }

    private func stopHLSPlayback() {
        stopExternalAudioPlayback()
        if let process = hlsProcess {
            Self.terminateProcessTree(process.processIdentifier)
            process.terminate()
        }
        hlsProcess = nil
        if let hlsDirectoryURL {
            try? FileManager.default.removeItem(at: hlsDirectoryURL)
        }
        hlsDirectoryURL = nil
        hlsPlaylistURL = nil
    }


    nonisolated private static func terminateMatchingProcesses(_ patterns: [String]) {
        for pattern in patterns {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-TERM", "-f", pattern]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    nonisolated private static func findJPEGStart(in data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        for index in 0..<(data.count - 1) where data[index] == 0xff && data[index + 1] == 0xd8 {
            return index
        }
        return nil
    }

    nonisolated private static func findJPEGEnd(in data: Data, after start: Int) -> Int? {
        guard data.count >= 2, start < data.count - 1 else { return nil }
        for index in start..<(data.count - 1) where data[index] == 0xff && data[index + 1] == 0xd9 {
            return index
        }
        return nil
    }

    nonisolated private static func hlsSegmentCount(in directory: URL) -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return items.filter { $0.hasPrefix("segment-") && $0.hasSuffix(".ts") }.count
    }

    private func renderFrame(from outputURL: URL) {
        guard !isExtractingFrame else { return }
        isExtractingFrame = true
        let elapsed = framePreviewStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let preferredOffset = max(1, Int(elapsed.rounded(.down)) - 1)
        let frameURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionem-dtv-frame-\(UUID().uuidString).jpg")
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? FileManager.default.removeItem(at: frameURL)
                DispatchQueue.main.async {
                    self.isExtractingFrame = false
                }
            }
            guard let ffmpeg = Self.findExecutable(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]) else {
                DispatchQueue.main.async {
                    self.detailLabel.stringValue = "ffmpeg nao encontrado para preview interno"
                }
                return
            }
            guard Self.extractFrame(ffmpeg: ffmpeg, inputURL: outputURL, outputURL: frameURL, preferredOffset: preferredOffset),
                  let image = NSImage(contentsOf: frameURL) else {
                return
            }
            DispatchQueue.main.async {
                self.frameView.image = image
                self.pipImageView.image = image
                self.statusLabel.isHidden = true
                self.detailLabel.isHidden = true
            }
        }
    }

    nonisolated private static func extractFrame(ffmpeg: String, inputURL: URL, outputURL: URL, preferredOffset: Int) -> Bool {
        let offset = max(1, preferredOffset)
        let previousOffset = max(1, offset - 2)
        let attempts: [[String]] = [
            ["-fflags", "+discardcorrupt", "-err_detect", "ignore_err", "-ss", "\(offset)"],
            ["-ss", "\(offset)"],
            ["-fflags", "+discardcorrupt", "-err_detect", "ignore_err", "-ss", "\(previousOffset)"],
            ["-ss", "\(previousOffset)"],
            ["-fflags", "+discardcorrupt", "-err_detect", "ignore_err"]
        ]
        for prefix in attempts {
            try? FileManager.default.removeItem(at: outputURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = prefix + [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", inputURL.path,
                "-map", "0:v:0",
                "-an",
                "-frames:v", "1",
                "-q:v", "3",
                outputURL.path
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                }
                process.waitUntilExit()
            } catch {
                continue
            }
            if process.terminationStatus == 0,
               FileManager.default.fileExists(atPath: outputURL.path) {
                return true
            }
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        channels.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ChannelCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        cell.subviews.forEach { $0.removeFromSuperview() }

        let channel = channels[row]
        cell.wantsLayer = false
        let title = NSTextField(labelWithString: channel.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        if channel.number <= 0 {
            title.textColor = .controlAccentColor
        } else if channel.demodLocked == true {
            title.textColor = .systemGreen
        } else if channel.rfLocked == true {
            title.textColor = .systemOrange
        } else if channel.rfLocked == false {
            title.textColor = .secondaryLabelColor
        } else {
            title.textColor = .labelColor
        }
        let subtitle = NSTextField(labelWithString: channel.subtitle)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 && row < channels.count else { return }
        startWatching(channels[row])
    }

    private func captureURL(for channel: Int) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        if channel <= 0 && channel > -100 {
            return movies.appendingPathComponent("SianoTV/fluxo-\(abs(channel)).ts")
        }
        return movies.appendingPathComponent("SianoTV/canal-\(physicalChannelNumber(for: channel)).ts")
    }

    private func isCurrentStreamChannel(_ channel: TVChannel) -> Bool {
        channel.scanStatus == "stream_atual" || (channel.frequency == 0 && channel.number <= 0 && channel.number > -100)
    }

    private func physicalChannelNumber(for channel: TVChannel) -> Int {
        physicalChannelNumber(for: channel.number)
    }

    private func physicalChannelNumber(for channelNumber: Int) -> Int {
        if channelNumber < -100 {
            return abs(channelNumber) / 100
        }
        return channelNumber
    }

    private static func currentStreamPlaceholder(name: String, index: Int) -> TVChannel {
        TVChannel(
            number: -index,
            band: "fluxo MPEG-TS atual",
            frequency: 0,
            name: name,
            rfLocked: true,
            demodLocked: true,
            scanStatus: "stream_atual"
        )
    }

    private func findSianoTVBinary() -> String? {
        var candidates: [String] = []
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent("siano-tv").path)
        }
        candidates.append(contentsOf: [
            "/usr/local/bin/siano-tv",
            "\(FileManager.default.currentDirectoryPath)/build/siano-tv"
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func channelsStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Visionem DTV/channels-br.json")
    }

    private func legacyChannelsStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Siano TV Digital/channels-br.json")
    }

    private func visionemChannelsStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Visionem/channels-br.json")
    }

    private func loadSavedChannels() -> [TVChannel] {
        guard let url = channelsStoreURL(),
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([TVChannel].self, from: data) else {
            return migrateLegacyChannels()
        }
        return Self.sortedChannels(saved)
    }

    private func migrateLegacyChannels() -> [TVChannel] {
        let candidateURLs = [visionemChannelsStoreURL(), legacyChannelsStoreURL()].compactMap { $0 }
        guard let sourceURL = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: sourceURL),
              let saved = try? JSONDecoder().decode([TVChannel].self, from: data) else {
            return []
        }
        channels = Self.sortedChannels(saved)
        persistChannels()
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
        return channels
    }

    private func persistChannels() {
        guard let url = channelsStoreURL() else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Self.sortedChannels(channels))
            try data.write(to: url, options: [.atomic])
        } catch {
            detailLabel.stringValue = "Nao foi possivel salvar canais: \(error.localizedDescription)"
        }
    }

    private func sortChannels() {
        channels = Self.sortedChannels(channels)
    }

    private static func sortedChannels(_ channels: [TVChannel]) -> [TVChannel] {
        channels.sorted { lhs, rhs in
            if lhs.number <= 0 && rhs.number <= 0 {
                return lhs.number > rhs.number
            }
            if lhs.number <= 0 { return true }
            if rhs.number <= 0 { return false }
            return lhs.number < rhs.number
        }
    }

    private func updateChannelNameFromTransportStream(_ url: URL, channelNumber: Int) {
        DispatchQueue.global(qos: .utility).async {
            guard let name = Self.detectServiceNames(in: url).first else { return }
            DispatchQueue.main.async {
                guard let index = self.channels.firstIndex(where: { $0.number == channelNumber }) else { return }
                if self.channels[index].name != name {
                    self.channels[index].name = name
                    self.tableView.reloadData()
                    self.persistChannels()
                }
            }
        }
    }

    nonisolated private static func detectServiceNames(in url: URL) -> [String] {
        guard let ffprobe = findExecutable(["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]) else {
            return []
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error",
            "-show_entries", "program_tags=service_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let deadline = Date().addingTimeInterval(6)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var grouped: [String: String] = [:]
        var order: [String] = []
        for line in output.split(separator: "\n") {
            let rawName = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedServiceKey(rawName)
            guard !rawName.isEmpty, key != "unknown" else { continue }
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = displayServiceName(rawName)
            } else if serviceNamePriority(rawName) > serviceNamePriority(grouped[key] ?? "") {
                grouped[key] = displayServiceName(rawName)
            }
        }
        return order.compactMap { grouped[$0] }
    }

    nonisolated private static func normalizedServiceKey(_ name: String) -> String {
        let lowercased = name.lowercased()
        let tokensToRemove = ["hd", "1seg", "1 seg", "one seg", "oneseg", "sd", "tv"]
        let normalized = tokensToRemove.reduce(lowercased) { partial, token in
            partial.replacingOccurrences(of: token, with: " ")
        }
        return normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func displayServiceName(_ name: String) -> String {
        let key = normalizedServiceKey(name)
        guard !key.isEmpty else { return name }
        let words = key.split(separator: " ").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.joined(separator: " ")
    }

    nonisolated private static func serviceNamePriority(_ name: String) -> Int {
        let lowercased = name.lowercased()
        if lowercased.contains("1seg") || lowercased.contains("1 seg") { return 0 }
        if lowercased.contains("hd") { return 2 }
        return 1
    }

    nonisolated private static func findExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func tailText(_ url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "sem log" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "log ilegivel")
            .split(separator: "\n")
            .suffix(4)
            .joined(separator: " | ")
    }

    nonisolated private static func terminateProcessTree(_ pid: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-TERM", "-P", "\(pid)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    nonisolated private static func detectCurrentTransmission(binary: String, probeSeconds: Int) -> TransmissionProbeResult {
        let usbState = runSianoTV(binary: binary, arguments: ["usb-state"], timeout: 4)
        if usbState.output.contains("LIBUSB_ERROR_ACCESS") {
            return .unavailable("O receptor esta ocupado por outro processo. Feche o Visionem DTV antigo ou finalize processos siano-tv e tente Buscar novamente.")
        }
        if !usbState.output.contains("summary: mdtv=1") && !usbState.output.contains("mdtv: present") {
            return .unavailable("Receptor USB nao encontrado. Reconecte o dongle e tente Buscar novamente. Diagnostico: \(usbState.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("siano-tv-current-stream-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["dump-ts", "\(probeSeconds)", outputURL.path]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return .unavailable(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(probeSeconds + 3))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return .none
        }
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            if text.contains("LIBUSB_ERROR_ACCESS") {
                return .unavailable("O receptor esta ocupado por outro processo. Feche o Visionem DTV antigo ou finalize processos siano-tv e tente Buscar novamente.")
            }
            if indicatesUnresponsiveReceiver(text) {
                return .unavailable("O receptor esta conectado, mas nao respondeu ao transporte USB. Reconecte fisicamente o dongle e tente Buscar novamente. Diagnostico: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if text.contains("not found") || text.contains("not openable") {
                return .unavailable("Receptor USB nao encontrado ou nao abriu. Reconecte o dongle e tente novamente.")
            }
            return .none
        }
        let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let serviceNames = detectServiceNames(in: outputURL)
        guard size > minimumPreviewBytes, !serviceNames.isEmpty else { return .none }
        return .found(TransmissionProbe(serviceNames: serviceNames, hasVideo: hasVideoStream(in: outputURL), bytes: size))
    }

    nonisolated private static func detectConfirmedPhysicalChannels(binary: String, scanText: String) -> [TVChannel] {
        let candidates = scanText
            .split(separator: "\n")
            .compactMap { parseScanCandidate(String($0)) }
            .filter { $0.channel.rfLocked == true }
            .sorted {
                if $0.channel.number == 18 { return true }
                if $1.channel.number == 18 { return false }
                return $0.power > $1.power
            }
            .prefix(6)

        var confirmed: [TVChannel] = []
        for candidate in candidates {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("visionem-dtv-scan-canal-\(candidate.channel.number)-\(UUID().uuidString).ts")
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let result = runSianoTV(
                binary: binary,
                arguments: ["ts-probe-br", "\(candidate.channel.number)", "12", outputURL.path],
                timeout: 22
            )
            let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard result.status == 0 || size > minimumPreviewBytes else { continue }
            let names = detectServiceNames(in: outputURL)
            guard !names.isEmpty, hasVideoStream(in: outputURL) else { continue }

            for (index, name) in names.enumerated() {
                let number = index == 0 ? candidate.channel.number : -(candidate.channel.number * 100 + index)
                confirmed.append(TVChannel(
                    number: number,
                    band: index == 0 ? candidate.channel.band : "servico do canal \(candidate.channel.number)",
                    frequency: candidate.channel.frequency,
                    name: name,
                    rfLocked: true,
                    demodLocked: true,
                    scanStatus: "ts_confirmado"
                ))
            }
        }
        return confirmed
    }

    nonisolated private static func indicatesUnresponsiveReceiver(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("libusb_error_timeout") ||
            lowercased.contains("bulk out failed") ||
            lowercased.contains("timeout waiting for response") ||
            lowercased == "timeout"
    }

    nonisolated private static func runSianoTV(binary: String, arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return (-2, "timeout")
        }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    nonisolated private static func hasVideoStream(in url: URL) -> Bool {
        guard let ffprobe = findExecutable(["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]) else {
            return false
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0",
            url.path
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(separator: "\n").contains("video")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: SianoController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = SianoController()
        controller?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stopWatching()
    }
}

func parseScanLine(_ text: String) -> TVChannel? {
    guard text.contains("canal="), text.contains("freq="), text.contains("rf="), text.contains("demod=") else { return nil }
    let parts = text.split(separator: " ")
    var number: Int?
    var bandParts: [String] = []
    var frequency: Int?
    var rf: Bool?
    var demod: Bool?
    var status: String?
    var readingBand = false
    for rawPart in parts {
        let part = String(rawPart)
        if part.hasPrefix("canal=") {
            number = Int(part.dropFirst("canal=".count))
            readingBand = false
        } else if part.hasPrefix("faixa=") {
            bandParts = [String(part.dropFirst("faixa=".count))]
            readingBand = true
        } else if part.hasPrefix("freq=") {
            frequency = Int(part.dropFirst("freq=".count))
            readingBand = false
        } else if part.hasPrefix("rf=") {
            rf = part.hasSuffix("1")
            readingBand = false
        } else if part.hasPrefix("demod=") {
            demod = part.hasSuffix("1")
            readingBand = false
        } else if part.hasPrefix("status=") {
            status = String(part.dropFirst("status=".count))
            readingBand = false
        } else if readingBand {
            bandParts.append(part)
        }
    }
    guard let number, let frequency else { return nil }
    return TVChannel(number: number, band: bandParts.joined(separator: " "), frequency: frequency, name: nil, rfLocked: rf, demodLocked: demod, scanStatus: status)
}

func parseScanCandidate(_ text: String) -> (channel: TVChannel, power: Int)? {
    guard let channel = parseScanLine(text) else { return nil }
    var power = Int.min
    for rawPart in text.split(separator: " ") {
        let part = String(rawPart)
        if part.hasPrefix("power="), let value = Int(part.dropFirst("power=".count)) {
            power = value
            break
        }
    }
    return (channel, power)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
