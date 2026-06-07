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

private let minimumPreviewBytes = 160 * 1024

@MainActor
final class SianoController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    private let window: NSWindow
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Selecione um canal para assistir")
    private let detailLabel = NSTextField(labelWithString: "Visionem DTV - ISDB-Tb Brasil")
    private let playerView = AVPlayerView()
    private let frameView = NSImageView()
    private let scanButton = NSButton(title: "Buscar", target: nil, action: nil)
    private let stopButton = NSButton(title: "Parar", target: nil, action: nil)
    private let pipButton = NSButton(title: "PIP", target: nil, action: nil)
    private var pipWindow: NSPanel?
    private let pipImageView = NSImageView()
    private var channels: [TVChannel] = []
    private var scanProcess: Process?
    private var watchProcess: Process?
    private var watchOutputPipe: Pipe?
    private var currentOutputURL: URL?
    private var currentChannelNumber: Int?
    private var playbackTimer: Timer?
    private var frameTimer: Timer?
    private var isExtractingFrame = false
    private var fallbackDumpStarted = false

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
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func configureWindow() {
        window.title = "Visionem DTV"
        window.titleVisibility = .hidden
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

        scanButton.target = self
        scanButton.action = #selector(refreshChannels)
        stopButton.target = self
        stopButton.action = #selector(stopWatching)
        pipButton.target = self
        pipButton.action = #selector(togglePIP)
        [scanButton, stopButton, pipButton].forEach { button in
            button.bezelStyle = .texturedRounded
            button.controlSize = .large
        }

        let controls = NSStackView(views: [scanButton, stopButton, pipButton])
        controls.orientation = .horizontal
        controls.distribution = .fillEqually
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Visionem DTV")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "TV digital brasileira")
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(title)
        sidebar.addSubview(subtitle)
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

            scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
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
        statusLabel.stringValue = "Carregando canais salvos..."
        channels = loadSavedChannels()
        tableView.reloadData()
        if channels.isEmpty {
            statusLabel.stringValue = "Nenhum canal salvo"
            detailLabel.stringValue = "Primeira execucao; iniciando varredura brasileira"
            startScan()
        } else {
            detailLabel.stringValue = "\(channels.count) canais salvos"
        }
    }

    @objc private func refreshChannels() {
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
        statusLabel.stringValue = "Limpando lista..."
        detailLabel.stringValue = "A varredura sera executada do zero"
    }

    @objc func stopWatching() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        isExtractingFrame = false
        scanProcess?.terminate()
        scanProcess = nil
        watchProcess?.terminate()
        watchProcess = nil
        watchOutputPipe?.fileHandleForReading.readabilityHandler = nil
        watchOutputPipe = nil
        currentOutputURL = nil
        currentChannelNumber = nil
        fallbackDumpStarted = false
        playerView.player?.pause()
        playerView.player = nil
        frameView.image = nil
        pipImageView.image = nil
        statusLabel.isHidden = false
        detailLabel.isHidden = false
        statusLabel.stringValue = "Parado"
        detailLabel.stringValue = "Selecione um canal para assistir"
    }

    private func startScan() {
        guard let binary = findSianoTVBinary() else {
            statusLabel.stringValue = "siano-tv nao encontrado"
            detailLabel.stringValue = "Instale o pacote antes de atualizar"
            return
        }

        channels = channels.map {
            TVChannel(number: $0.number, band: $0.band, frequency: $0.frequency, name: $0.name, rfLocked: nil, demodLocked: nil, scanStatus: "aguardando")
        }
        tableView.reloadData()
        scanButton.isEnabled = false
        statusLabel.stringValue = "Procurando transmissao ativa..."
        detailLabel.stringValue = "Primeiro teste: MPEG-TS ja entregue pelo firmware"

        DispatchQueue.global(qos: .userInitiated).async {
            switch Self.detectCurrentTransmission(binary: binary, probeSeconds: 20) {
            case .found(let activeTransmission) where activeTransmission.hasVideo:
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.channels.removeAll()
                    for (index, serviceName) in activeTransmission.serviceNames.enumerated() {
                        self.applyScanResult(Self.currentStreamPlaceholder(name: serviceName, index: index))
                    }
                    self.scanButton.isEnabled = true
                    self.persistChannels()
                    self.statusLabel.stringValue = "Transmissao ativa encontrada"
                    let suffix = self.channels.count == 1 ? "servico detectado" : "servicos detectados"
                    self.detailLabel.stringValue = "\(self.channels.count) \(suffix) no fluxo atual"
                    self.autoStartCurrentStreamIfAvailable()
                }
                return
            case .unavailable(let message):
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.scanButton.isEnabled = true
                    self.statusLabel.stringValue = "Dispositivo ocupado"
                    self.detailLabel.stringValue = message
                }
                return
            case .found, .none:
                break
            }

            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["scan-br"]
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                DispatchQueue.main.async {
                    self.scanProcess = process
                }
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                let scanned = text
                    .split(separator: "\n")
                    .compactMap { parseScanLine(String($0)) }
                    .filter { $0.demodLocked == true }
                let currentTransmission = Self.detectCurrentTransmission(binary: binary, probeSeconds: 12)
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.channels.removeAll()
                    for channel in scanned where channel.name != nil && channel.name?.isEmpty == false {
                        self.applyScanResult(channel)
                    }
                    if case .found(let currentTransmission) = currentTransmission, currentTransmission.hasVideo {
                        for (index, serviceName) in currentTransmission.serviceNames.enumerated() {
                            self.applyScanResult(Self.currentStreamPlaceholder(name: serviceName, index: index))
                        }
                    }
                    self.scanButton.isEnabled = true
                    self.persistChannels()
                    if case .unavailable(let message) = currentTransmission {
                        self.statusLabel.stringValue = "Dispositivo ocupado"
                        self.detailLabel.stringValue = message
                    } else if self.channels.isEmpty {
                        self.statusLabel.stringValue = "Nenhuma transmissao encontrada"
                        self.detailLabel.stringValue = "A busca so lista canais com TS, video e nome de servico confirmados"
                    } else {
                        self.statusLabel.stringValue = "Busca concluida"
                        let suffix = self.channels.count == 1 ? "transmissao encontrada" : "transmissoes encontradas"
                        self.detailLabel.stringValue = "\(self.channels.count) \(suffix)"
                    }
                    self.autoStartCurrentStreamIfAvailable()
                }
            } catch {
                DispatchQueue.main.async {
                    self.scanProcess = nil
                    self.scanButton.isEnabled = true
                    self.statusLabel.stringValue = "Falha ao atualizar"
                    self.detailLabel.stringValue = error.localizedDescription
                }
            }
        }
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
        statusLabel.stringValue = "Canal \(updated.number): \(updated.scanStatus ?? "testado")"
        detailLabel.stringValue = updated.subtitle
    }

    private func startWatching(_ channel: TVChannel) {
        stopWatching()
        let outputURL = captureURL(for: channel.number)
        currentOutputURL = outputURL
        currentChannelNumber = channel.number
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let binary = findSianoTVBinary() else {
            statusLabel.stringValue = "siano-tv nao encontrado"
            detailLabel.stringValue = "Instale o pacote ou compile o projeto antes de assistir"
            return
        }

        fallbackDumpStarted = false
        if channel.number <= 0 {
            fallbackDumpStarted = true
            runWatchProcess(binary: binary, arguments: ["dump-ts", "3600", outputURL.path], outputURL: outputURL, channel: channel, isFallback: true)
        } else {
            runWatchProcess(binary: binary, arguments: ["watch-br", "\(channel.number)", "3600", outputURL.path], outputURL: outputURL, channel: channel, isFallback: false)
        }
    }

    private func shouldStartWithDump(binary: String) -> Bool {
        let version = runShortCommand(binary: binary, arguments: ["version"])
        if version.exitCode == 0 {
            return false
        }
        return isMDTVPresent(binary: binary)
    }

    private func isMDTVPresent(binary: String) -> Bool {
        let state = runShortCommand(binary: binary, arguments: ["usb-state"])
        return state.output.contains("mdtv=1")
    }

    private func runShortCommand(binary: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(4)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func runWatchProcess(binary: String, arguments: [String], outputURL: URL, channel: TVChannel, isFallback: Bool) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        watchProcess = process
        watchOutputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.applyWatchOutput(text)
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.watchProcess === process else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size < 188 * 20 {
                    self.statusLabel.stringValue = "Sem stream MPEG-TS"
                    self.detailLabel.stringValue = channel.number <= 0
                        ? "Ajuste a posicao do dongle e tente novamente"
                        : "Nao foi possivel sintonizar este canal fisico agora"
                }
            }
        }

        do {
            try process.run()
            statusLabel.stringValue = isFallback ? "Lendo stream MPEG-TS..." : "Sintonizando \(channel.title)..."
            detailLabel.stringValue = isFallback ? outputURL.path : channel.subtitle
            schedulePlaybackProbe(outputURL, channelNumber: channel.number)
        } catch {
            statusLabel.stringValue = isFallback ? "Falha no fallback TS" : "Falha ao iniciar recepcao"
            detailLabel.stringValue = error.localizedDescription
        }
    }

    private func applyWatchOutput(_ text: String) {
        let lines = text.split(separator: "\n").map(String.init)
        guard let line = lines.last else { return }
        if line.contains("bytes=") {
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        } else if line.contains("demod lock") {
            statusLabel.stringValue = "Sinal digital travado"
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        } else if line.contains("final bytes") {
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        } else if line.contains("failed") {
            detailLabel.stringValue = line.trimmingCharacters(in: .whitespaces)
        }
    }

    private func schedulePlaybackProbe(_ outputURL: URL, channelNumber: Int) {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return }
                let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > minimumPreviewBytes {
                    self.updateChannelNameFromTransportStream(outputURL, channelNumber: channelNumber)
                    self.startFramePreview(outputURL)
                    self.statusLabel.stringValue = "Recebendo transmissao"
                    self.detailLabel.stringValue = outputURL.path
                    self.playbackTimer?.invalidate()
                    self.playbackTimer = nil
                } else {
                    self.statusLabel.isHidden = false
                    self.detailLabel.isHidden = false
                    self.statusLabel.stringValue = "Aguardando video..."
                    self.detailLabel.stringValue = "Recebendo TS; aguardando pacotes de video suficientes"
                }
            }
        }
    }

    private func startFramePreview(_ outputURL: URL) {
        frameTimer?.invalidate()
        renderFrame(from: outputURL)
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.renderFrame(from: outputURL)
            }
        }
    }

    private func renderFrame(from outputURL: URL) {
        guard !isExtractingFrame else { return }
        isExtractingFrame = true
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
            guard Self.extractFrame(ffmpeg: ffmpeg, inputURL: outputURL, outputURL: frameURL),
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

    nonisolated private static func extractFrame(ffmpeg: String, inputURL: URL, outputURL: URL) -> Bool {
        let attempts: [[String]] = [
            [],
            ["-ss", "2"],
            ["-ss", "5"],
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

    private func runChannelsCommand(extended: Bool) -> [TVChannel] {
        guard let binary = findSianoTVBinary() else { return [] }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [extended ? "channels-br-extended" : "channels-br"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap(parseChannelLine)
    }

    private func parseChannelLine(_ line: Substring) -> TVChannel? {
        let text = String(line)
        guard text.contains("canal="), text.contains("freq=") else { return nil }
        let parts = text.split(separator: " ")
        var number: Int?
        var bandParts: [String] = []
        var frequency: Int?
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
            } else if readingBand {
                bandParts.append(part)
            }
        }
        guard let number, let frequency else { return nil }
        return TVChannel(number: number, band: bandParts.joined(separator: " "), frequency: frequency, name: nil, rfLocked: nil, demodLocked: nil, scanStatus: nil)
    }

    private func captureURL(for channel: Int) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        if channel <= 0 {
            return movies.appendingPathComponent("SianoTV/fluxo-\(abs(channel)).ts")
        }
        return movies.appendingPathComponent("SianoTV/canal-\(channel).ts")
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
        let candidates = [
            "/usr/local/bin/siano-tv",
            "\(FileManager.default.currentDirectoryPath)/build/siano-tv"
        ]
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
        var names: [String] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            let name = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, key != "unknown", !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(name)
        }
        return names
    }

    nonisolated private static func findExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func detectCurrentTransmission(binary: String, probeSeconds: Int) -> TransmissionProbeResult {
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
