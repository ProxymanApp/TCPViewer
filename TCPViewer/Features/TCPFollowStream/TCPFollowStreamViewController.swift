//
//  TCPFollowStreamViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import AppKit
import PcapPlusPlusCore

private final class TCPFollowTextView: NSTextView {
    var packetRanges: [TCPFollowPacketRange] = [] {
        didSet {
            hideRevealButton()
        }
    }
    var revealPacket: ((TCPFollowRevealTarget) -> Void)?
    private let revealButton = NSButton()
    private var hoveredRevealTarget: TCPFollowRevealTarget?
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupRevealButton()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setupRevealButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupRevealButton()
    }

    // Track hover only inside the visible transcript viewport.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        updateRevealButton(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateRevealButton(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hideRevealButton()
    }

    private func setupRevealButton() {
        revealButton.title = ""
        revealButton.image = TCPViewerUI.image("arrow.right.circle")
        revealButton.imagePosition = .imageOnly
        revealButton.bezelStyle = .inline
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(revealHoveredPacket(_:))
        revealButton.toolTip = "Reveal packet in main table"
        revealButton.setAccessibilityLabel("Reveal packet in main table")
        revealButton.isHidden = true
        addSubview(revealButton)
    }

    // Move one reusable button beside the header for the record under the pointer.
    private func updateRevealButton(at point: NSPoint) {
        guard let packetRange = packetRange(at: point),
              let buttonFrame = revealButtonFrame(for: packetRange) else {
            hideRevealButton()
            return
        }
        hoveredRevealTarget = packetRange.revealTarget
        revealButton.frame = buttonFrame
        revealButton.isHidden = false
    }

    // Resolve a record by vertical text layout so the full visible row remains hoverable.
    private func packetRange(at point: NSPoint) -> TCPFollowPacketRange? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else {
            return nil
        }
        layoutManager.ensureLayout(for: textContainer)
        let containerOrigin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - containerOrigin.x, y: point.y - containerOrigin.y)
        guard containerPoint.y >= 0 else {
            return nil
        }
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            return nil
        }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard let packetRange = packetRanges.first(where: { NSLocationInRange(characterIndex, $0.range) }) else {
            return nil
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: packetRange.range, actualCharacterRange: nil)
        let recordBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard containerPoint.y >= recordBounds.minY, containerPoint.y <= recordBounds.maxY else {
            return nil
        }
        return packetRange
    }

    // Position the action after the packet header without changing transcript text or selection.
    private func revealButtonFrame(for packetRange: TCPFollowPacketRange) -> NSRect? {
        guard let layoutManager, let textContainer, packetRange.range.location < textStorage?.length ?? 0 else {
            return nil
        }
        let headerLineRange = (string as NSString).lineRange(
            for: NSRange(location: packetRange.range.location, length: 0)
        )
        let headerLength = max(headerLineRange.length - 1, 0)
        let headerRange = NSRange(location: headerLineRange.location, length: headerLength)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: headerRange, actualCharacterRange: nil)
        let headerBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let buttonSize = NSSize(width: 22, height: 18)
        let origin = textContainerOrigin
        let maximumX = max(origin.x, bounds.width - buttonSize.width - 6)
        return NSRect(
            x: min(origin.x + headerBounds.maxX + 5, maximumX),
            y: origin.y + headerBounds.midY - buttonSize.height / 2,
            width: buttonSize.width,
            height: buttonSize.height
        )
    }

    private func hideRevealButton() {
        hoveredRevealTarget = nil
        revealButton.isHidden = true
    }

    @objc private func revealHoveredPacket(_ sender: NSButton) {
        guard let hoveredRevealTarget else {
            return
        }
        revealPacket?(hoveredRevealTarget)
    }
}

final class TCPFollowStreamViewController: NSViewController, NSSearchFieldDelegate {
    var revealPacket: ((TCPFollowRevealTarget) -> Void)?
    var requestStream: ((TCPFollowStreamNavigation.Entry) -> Void)?

    private let viewModel = TCPFollowStreamViewModel()
    private let settingsLabel = NSTextField(labelWithString: "Settings:")
    private let directionControl = NSSegmentedControl(
        labels: ["Both", "Client → Server", "Server → Client"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let representationControl = NSSegmentedControl(
        labels: ["Text", "Hex"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let settingsStack = NSStackView()
    private let settingsSpacer = NSView()
    private let streamLabel = NSTextField(labelWithString: "Stream:")
    private let streamIDLabel = NSTextField(labelWithString: "—")
    private let streamStepper = NSStepper()
    private let streamStack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let placeholderLabel = NSTextField(labelWithString: "Reassembling TCP stream…")
    private let progressIndicator = NSProgressIndicator()
    private let scrollView = TCPFollowTextView.scrollableTextView()
    private lazy var textView: TCPFollowTextView = {
        guard let textView = scrollView.documentView as? TCPFollowTextView else {
            preconditionFailure("The follow stream scroll view must contain TCPFollowTextView.")
        }
        return textView
    }()
    private let searchContainer = NSView()
    private let searchSeparator = NSBox()
    private let searchField = NSSearchField()
    private let searchMatchLabel = NSTextField(labelWithString: "0 of 0")
    private let previousMatchButton = NSButton()
    private let nextMatchButton = NSButton()
    private let searchStack = NSStackView()
    private let placeholderStack = NSStackView()
    private let searchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.TCPFollowStream.search", qos: .userInitiated)
    private var latestRenderedContent: TCPFollowRenderedContent?
    private var streamNavigation: TCPFollowStreamNavigation?
    private var searchGeneration = 0
    private var searchQuery = ""
    private var searchMatchCount = 0
    private var currentMatchNumber = 0
    private var currentMatchRange: NSRange?
    private var searchCancellationFlag: TCPFollowCancellationFlag?

    var stream: TCPFollowStream? {
        viewModel.stream
    }

    var renderedContent: TCPFollowRenderedContent {
        latestRenderedContent ?? viewModel.renderedContent()
    }

    override func loadView() {
        view = NSView()
        setupView()
    }

    // Reflow hex rows only when resizing changes the number of complete columns that fit.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard updateHexBytesPerLineIfNeeded() else {
            return
        }
        render()
    }

    // Display an indeterminate loading state before the core reports packet counts.
    func showLoading() {
        summaryLabel.stringValue = "Preparing packet snapshot"
        placeholderLabel.stringValue = "Reassembling TCP stream…"
        progressIndicator.isHidden = false
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        placeholderStack.isHidden = false
        scrollView.isHidden = true
        suspendSearch()
    }

    // Update bounded reassembly progress without exposing payload data.
    func updateProgress(_ progress: TCPFollowProgress) {
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = Double(max(progress.totalPacketCount, 1))
        progressIndicator.doubleValue = Double(progress.processedPacketCount)
        placeholderLabel.stringValue = "Reassembling packet \(progress.processedPacketCount.formatted()) of \(progress.totalPacketCount.formatted())…"
    }

    // Render the completed immutable stream snapshot.
    func show(stream: TCPFollowStream) {
        progressIndicator.stopAnimation(nil)
        viewModel.setStream(stream)
        let client = endpointLabel(stream.client)
        let server = endpointLabel(stream.server)
        summaryLabel.stringValue = "\(client)  ⇄  \(server)"
        placeholderStack.isHidden = true
        scrollView.isHidden = false
        searchField.isEnabled = true
        updateHexBytesPerLineIfNeeded()
        render()
    }

    // Replace the progress state with a concise recoverable error.
    func show(error: Error) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        placeholderLabel.stringValue = error.localizedDescription
        summaryLabel.stringValue = "Follow TCP Stream"
        placeholderStack.isHidden = false
        scrollView.isHidden = true
        suspendSearch()
    }

    // Apply the direction control to the already-reassembled snapshot.
    func setDirectionFilter(_ filter: TCPFollowDirectionFilter) {
        directionControl.selectedSegment = filter.rawValue
        viewModel.setDirectionFilter(filter)
        render()
    }

    // Apply the text/hex control to the already-reassembled snapshot.
    func setRepresentation(_ representation: TCPFollowRepresentation) {
        representationControl.selectedSegment = representation.rawValue
        viewModel.setRepresentation(representation)
        updateHexBytesPerLineIfNeeded()
        render()
    }

    // Update the displayed stream ID and the stepper's available range.
    func setStreamNavigation(_ navigation: TCPFollowStreamNavigation, isEnabled: Bool) {
        streamNavigation = navigation
        updateStreamNavigationControls(isEnabled: isEnabled)
    }

    // Prevent another navigation request while the selected stream is loading.
    func setStreamNavigationEnabled(_ isEnabled: Bool) {
        updateStreamNavigationControls(isEnabled: isEnabled)
    }

    // Move keyboard focus to the dedicated transcript search field.
    func focusSearch() {
        guard searchField.isEnabled, let window = view.window else {
            return
        }
        window.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    // Recount matches as the user edits the dedicated search field.
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else {
            return
        }
        refreshSearchResults()
    }

    private func setupView() {
        // Keep display controls together at the leading edge of the settings row.
        settingsLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        directionControl.selectedSegment = TCPFollowDirectionFilter.both.rawValue
        directionControl.target = self
        directionControl.action = #selector(directionChanged(_:))
        directionControl.setAccessibilityLabel("Stream direction")
        representationControl.selectedSegment = TCPFollowRepresentation.text.rawValue
        representationControl.target = self
        representationControl.action = #selector(representationChanged(_:))
        representationControl.setAccessibilityLabel("Payload representation")
        settingsStack.orientation = .horizontal
        settingsStack.alignment = .centerY
        settingsStack.spacing = 10
        settingsStack.addArrangedSubview(settingsLabel)
        settingsStack.addArrangedSubview(directionControl)
        settingsStack.addArrangedSubview(representationControl)
        settingsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        settingsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        settingsStack.addArrangedSubview(settingsSpacer)

        // Keep stream navigation visible at the trailing edge as the window grows.
        streamIDLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        streamIDLabel.alignment = .right
        streamStepper.increment = 1
        streamStepper.valueWraps = false
        streamStepper.target = self
        streamStepper.action = #selector(streamChanged(_:))
        streamStepper.toolTip = "Previous or next TCP stream"
        streamStepper.setAccessibilityLabel("TCP stream")
        streamStepper.isEnabled = false
        streamStack.orientation = .horizontal
        streamStack.alignment = .centerY
        streamStack.spacing = 6
        streamStack.addArrangedSubview(streamLabel)
        streamStack.addArrangedSubview(streamIDLabel)
        streamStack.addArrangedSubview(streamStepper)
        streamStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsStack.addArrangedSubview(streamStack)

        summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        // Configure one selectable transcript for both text and hex representations.
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.revealPacket = { [weak self] target in
            self?.revealPacket?(target)
        }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // Place bounded search controls beneath the transcript instead of using AppKit's find bar.
        searchSeparator.boxType = .separator
        searchField.placeholderString = "Search transcript ⌘F"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchSubmitted(_:))
        searchField.setAccessibilityLabel("Search TCP stream")
        searchField.isEnabled = false
        searchMatchLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        searchMatchLabel.textColor = .secondaryLabelColor
        searchMatchLabel.alignment = .center

        previousMatchButton.title = ""
        previousMatchButton.image = TCPViewerUI.image("chevron.up")
        previousMatchButton.imagePosition = .imageOnly
        previousMatchButton.bezelStyle = .texturedRounded
        previousMatchButton.target = self
        previousMatchButton.action = #selector(findPrevious(_:))
        previousMatchButton.toolTip = "Previous match"
        previousMatchButton.setAccessibilityLabel("Previous match")
        previousMatchButton.isEnabled = false
        nextMatchButton.title = ""
        nextMatchButton.image = TCPViewerUI.image("chevron.down")
        nextMatchButton.imagePosition = .imageOnly
        nextMatchButton.bezelStyle = .texturedRounded
        nextMatchButton.target = self
        nextMatchButton.action = #selector(findNext(_:))
        nextMatchButton.toolTip = "Next match"
        nextMatchButton.setAccessibilityLabel("Next match")
        nextMatchButton.isEnabled = false

        searchStack.orientation = .horizontal
        searchStack.alignment = .centerY
        searchStack.spacing = 8
        searchStack.addArrangedSubview(searchField)
        searchStack.addArrangedSubview(searchMatchLabel)
        searchStack.addArrangedSubview(previousMatchButton)
        searchStack.addArrangedSubview(nextMatchButton)

        // Center progress feedback while reassembly hides the transcript.
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 3
        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 12
        placeholderStack.addArrangedSubview(placeholderLabel)
        placeholderStack.addArrangedSubview(progressIndicator)

        [searchSeparator, searchStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            searchContainer.addSubview($0)
        }
        [settingsStack, summaryLabel, statusLabel, scrollView, searchContainer, placeholderStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            settingsStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            settingsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            settingsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            streamIDLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            summaryLabel.topAnchor.constraint(equalTo: settingsStack.bottomAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: summaryLabel.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            searchContainer.heightAnchor.constraint(equalToConstant: 44),
            searchSeparator.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchSeparator.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor),
            searchSeparator.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor),
            searchStack.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 14),
            searchStack.trailingAnchor.constraint(lessThanOrEqualTo: searchContainer.trailingAnchor, constant: -14),
            searchStack.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor, constant: 1),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            searchMatchLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            previousMatchButton.widthAnchor.constraint(equalToConstant: 28),
            nextMatchButton.widthAnchor.constraint(equalToConstant: 28),
            placeholderStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderStack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
            progressIndicator.widthAnchor.constraint(equalToConstant: 260),
        ])
        showLoading()
    }

    @objc private func directionChanged(_ sender: NSSegmentedControl) {
        guard let filter = TCPFollowDirectionFilter(rawValue: sender.selectedSegment) else {
            return
        }
        setDirectionFilter(filter)
    }

    @objc private func representationChanged(_ sender: NSSegmentedControl) {
        guard let representation = TCPFollowRepresentation(rawValue: sender.selectedSegment) else {
            return
        }
        setRepresentation(representation)
    }

    @objc private func searchSubmitted(_ sender: NSSearchField) {
        findNext(sender)
    }

    @objc private func findPrevious(_ sender: Any?) {
        moveToMatch(forward: false)
    }

    @objc private func findNext(_ sender: Any?) {
        moveToMatch(forward: true)
    }

    @objc private func streamChanged(_ sender: NSStepper) {
        guard let streamNavigation else {
            updateStreamNavigationControls(isEnabled: false)
            return
        }
        let currentStreamID = Double(streamNavigation.selectedEntry.streamID)
        let requestedIndex = sender.doubleValue > currentStreamID
            ? streamNavigation.selectedIndex + 1
            : streamNavigation.selectedIndex - 1
        guard let updatedNavigation = streamNavigation.selecting(index: requestedIndex),
              updatedNavigation.selectedIndex != streamNavigation.selectedIndex,
              let requestStream else {
            updateStreamNavigationControls(isEnabled: true)
            return
        }
        self.streamNavigation = updatedNavigation
        updateStreamNavigationControls(isEnabled: false)
        requestStream(updatedNavigation.selectedEntry)
    }

    // Keep the stream label and native stepper synchronized with the selected index.
    private func updateStreamNavigationControls(isEnabled: Bool) {
        guard let streamNavigation,
              let firstEntry = streamNavigation.entries.first,
              let lastEntry = streamNavigation.entries.last else {
            streamIDLabel.stringValue = "—"
            streamStepper.isEnabled = false
            return
        }
        streamIDLabel.stringValue = String(streamNavigation.selectedEntry.streamID)
        streamStepper.minValue = Double(firstEntry.streamID)
        streamStepper.maxValue = Double(lastEntry.streamID)
        streamStepper.doubleValue = Double(streamNavigation.selectedEntry.streamID)
        streamStepper.isEnabled = isEnabled && streamNavigation.entries.count > 1
    }

    // Invalidate queued searches while the transcript is unavailable.
    private func suspendSearch() {
        searchGeneration &+= 1
        searchCancellationFlag?.cancel()
        searchCancellationFlag = nil
        searchField.isEnabled = false
        searchQuery = searchField.stringValue
        searchMatchCount = 0
        currentMatchNumber = 0
        currentMatchRange = nil
        searchMatchLabel.stringValue = "0 of 0"
        previousMatchButton.isEnabled = false
        nextMatchButton.isEnabled = false
    }

    // Count matches off the main queue, retaining only the active range to bound memory use.
    private func refreshSearchResults() {
        searchGeneration &+= 1
        searchCancellationFlag?.cancel()
        searchCancellationFlag = nil
        let generation = searchGeneration
        let query = searchField.stringValue
        searchQuery = query
        searchMatchCount = 0
        currentMatchNumber = 0
        currentMatchRange = nil
        previousMatchButton.isEnabled = false
        nextMatchButton.isEnabled = false

        guard searchField.isEnabled, !query.isEmpty else {
            searchMatchLabel.stringValue = "0 of 0"
            return
        }

        searchMatchLabel.stringValue = "Searching…"
        let searchableText = textView.string
        let cancellationFlag = TCPFollowCancellationFlag()
        searchCancellationFlag = cancellationFlag
        searchQueue.async {
            guard let summary = Self.searchSummary(
                in: searchableText,
                query: query,
                shouldCancel: { cancellationFlag.isCancelled }
            ) else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.searchGeneration == generation,
                      self.searchField.stringValue == query else {
                    return
                }
                self.applySearchSummary(summary)
            }
        }
    }

    // Find the exact count and first non-overlapping match without retaining every range.
    private static func searchSummary(
        in text: String,
        query: String,
        shouldCancel: () -> Bool
    ) -> (count: Int, firstRange: NSRange?)? {
        let source = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var remainingRange = NSRange(location: 0, length: source.length)
        var firstRange: NSRange?
        var count = 0

        while remainingRange.length > 0 {
            if count.isMultiple(of: 256), shouldCancel() {
                return nil
            }
            let match = source.range(of: query, options: options, range: remainingRange)
            guard match.location != NSNotFound else {
                break
            }
            firstRange = firstRange ?? match
            count += 1
            let nextLocation = NSMaxRange(match)
            guard nextLocation < source.length else {
                break
            }
            remainingRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return shouldCancel() ? nil : (count, firstRange)
    }

    // Apply the latest generation only, selecting and revealing its first match.
    private func applySearchSummary(_ summary: (count: Int, firstRange: NSRange?)) {
        searchMatchCount = summary.count
        guard summary.count > 0, let firstRange = summary.firstRange else {
            searchMatchLabel.stringValue = "0 of 0"
            return
        }
        currentMatchNumber = 1
        currentMatchRange = firstRange
        previousMatchButton.isEnabled = true
        nextMatchButton.isEnabled = true
        selectMatch(firstRange)
    }

    // Move in either direction and wrap when the active match is at an edge.
    private func moveToMatch(forward: Bool) {
        guard searchMatchCount > 0,
              !searchQuery.isEmpty,
              let currentMatchRange else {
            return
        }

        let source = textView.string as NSString
        let baseOptions: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let match: NSRange
        if forward {
            let nextLocation = NSMaxRange(currentMatchRange)
            let remainingRange = NSRange(location: nextLocation, length: source.length - nextLocation)
            let nextMatch = source.range(of: searchQuery, options: baseOptions, range: remainingRange)
            match = nextMatch.location == NSNotFound
                ? source.range(of: searchQuery, options: baseOptions, range: NSRange(location: 0, length: source.length))
                : nextMatch
            currentMatchNumber = currentMatchNumber == searchMatchCount ? 1 : currentMatchNumber + 1
        } else {
            let previousOptions = baseOptions.union(.backwards)
            let precedingRange = NSRange(location: 0, length: currentMatchRange.location)
            let previousMatch = source.range(of: searchQuery, options: previousOptions, range: precedingRange)
            match = previousMatch.location == NSNotFound
                ? source.range(of: searchQuery, options: previousOptions, range: NSRange(location: 0, length: source.length))
                : previousMatch
            currentMatchNumber = currentMatchNumber == 1 ? searchMatchCount : currentMatchNumber - 1
        }

        guard match.location != NSNotFound else {
            refreshSearchResults()
            return
        }
        self.currentMatchRange = match
        selectMatch(match)
    }

    // Select the active result and scroll it into view without stealing focus from search.
    private func selectMatch(_ range: NSRange) {
        guard NSMaxRange(range) <= textView.string.utf16.count else {
            return
        }
        searchMatchLabel.stringValue = "\(currentMatchNumber) of \(searchMatchCount)"
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    // Refresh only presentation state; core reassembly is intentionally not repeated.
    private func render() {
        guard viewModel.stream != nil else {
            return
        }
        let content = viewModel.renderedContent()
        latestRenderedContent = content
        textView.textStorage?.setAttributedString(content.attributedText)
        textView.packetRanges = content.packetRanges
        statusLabel.stringValue = content.statusText
        refreshSearchResults()
    }

    // Convert the viewport width into complete offset, byte, and ASCII columns.
    @discardableResult
    private func updateHexBytesPerLineIfNeeded() -> Bool {
        guard viewModel.stream != nil, viewModel.representation == .hex else {
            return false
        }
        let textInsets = textView.textContainerInset.width * 2
        let fragmentPadding = (textView.textContainer?.lineFragmentPadding ?? 0) * 2
        let availableWidth = max(scrollView.contentSize.width - textInsets - fragmentPadding, 0)
        let byteCount = TCPFollowStreamViewModel.preferredHexBytesPerLine(for: availableWidth)
        guard byteCount != viewModel.hexBytesPerLine else {
            return false
        }
        viewModel.setHexBytesPerLine(byteCount)
        return true
    }

    private func endpointLabel(_ endpoint: PacketEndpoint) -> String {
        let address = endpoint.address ?? "Unknown"
        return endpoint.port.map { "\(address):\($0)" } ?? address
    }
}
