import UIKit

/// 简体中文's candidate bar, as 豆包's is: the pinyin composing on a line of its own above,
/// its syllables joined by "'", and the words below it — the first in a filled capsule,
/// because Space puts that one in, the rest plain beside it.
///
/// It pages: the chevrons at the trailing edge bring the rest. The bar sits exactly where the
/// strip does (`KeyboardLayout.stripFrame`), so the Hex key keeps its place and the keys never
/// move.
@MainActor
final class ChineseCandidateBar: UIView {
    /// A word picked: the engine puts it in place of the run's letters.
    var onPick: ((String) -> Void)?
    /// A page turned: true forward.
    var onPage: ((_ forward: Bool) -> Void)?

    var palette = FullKeyboardPalette(isDark: false) {
        didSet { if palette != oldValue { applyPalette() } }
    }

    /// The words on offer, and how the run was read to spell them.
    private var words: [String] = []
    private var buffer = ""
    private var spelling = ""
    private var corrected = false
    private var generation = -1
    /// Where each page's words start: a page holds as many as its own widths leave room for.
    private var pageStarts: [Int] = [0]
    private var page = 0
    /// The width the words were last split for.
    private var splitWidth: CGFloat = 0

    private let pinyinLabel = UILabel()
    private var slots: [CandidateButton] = []
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)

    private static let wordFont = UIFont.systemFont(ofSize: 16)
    private static let firstWordFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
    /// Room a word keeps on either side of its text: the capsule needs a little more.
    private static let wordPadding: CGFloat = 20
    private static let firstWordPadding: CGFloat = 24
    private static let inset: CGFloat = 8
    /// The two chevrons' cell at the trailing edge: always reserved, so paging never re-splits.
    private static let arrowCell: CGFloat = 32
    private static let arrowWidth: CGFloat = 16
    private static let capsuleRadius: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        pinyinLabel.font = .systemFont(ofSize: 11)
        pinyinLabel.lineBreakMode = .byTruncatingTail
        pinyinLabel.isUserInteractionEnabled = false
        addSubview(pinyinLabel)
        configureArrow(previousButton, symbol: "chevron.left")
        configureArrow(nextButton, symbol: "chevron.right")
        previousButton.addTarget(self, action: #selector(turnBack), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(turnForward), for: .touchUpInside)
        addSubview(previousButton)
        addSubview(nextButton)
        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError("ChineseCandidateBar is laid out by hand") }

    private func configureArrow(_ button: UIButton, symbol: String) {
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        button.setImage(image, for: .normal)
        button.isHidden = true
    }

    /// The run's pinyin, its words, and whether the run is new (the bar then shows its first
    /// page). `spelling` is the pinyin as the dictionary read it, with a typo already repaired.
    func show(buffer: String, spelling: String, corrected: Bool, words: [String], generation: Int) {
        if buffer != self.buffer || spelling != self.spelling || corrected != self.corrected {
            self.buffer = buffer
            self.spelling = spelling
            self.corrected = corrected
            pinyinLabel.attributedText = pinyinLine()
            setNeedsLayout()
        }
        if generation != self.generation {
            self.generation = generation
            if page != 0 {
                page = 0
                rebuild()
            }
        }
        if words != self.words {
            self.words = words
            page = 0
            rebuild()
        }
    }

    /// The line above the words: the run as it was read — with the syllables apart, as 豆包
    /// shows them — and, where a typo had to be repaired, what was typed and what it read as.
    private func pinyinLine() -> NSAttributedString? {
        guard !buffer.isEmpty else { return nil }
        let plain: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: palette.stripText,
        ]
        guard PinyinDictionary.shared.isLoaded else {
            return NSAttributedString(string: String(localized: "Dictionary missing"), attributes: plain)
        }
        guard corrected, !spelling.isEmpty else {
            return NSAttributedString(string: spelling.isEmpty ? buffer : spelling, attributes: plain)
        }
        let repaired: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: palette.actionFill,
        ]
        let line = NSMutableAttributedString(string: buffer, attributes: plain)
        line.append(NSAttributedString(string: "  →  ", attributes: plain))
        line.append(NSAttributedString(string: spelling, attributes: repaired))
        return line
    }

    // MARK: - Words

    /// The width a word asks for, its capsule and the space beside it included.
    private func width(of word: String, first: Bool) -> CGFloat {
        let font = first ? Self.firstWordFont : Self.wordFont
        let text = (word as NSString).size(withAttributes: [.font: font]).width
        return ceil(text + (first ? Self.firstWordPadding : Self.wordPadding))
    }

    /// The room the words have: the bar, less its insets and the chevrons' cell.
    private var wordsWidth: CGFloat {
        max(120, bounds.width - 2 * Self.inset - Self.arrowCell)
    }

    /// Splits the words into pages by their own widths: a page holds what fits, so a row of
    /// characters takes more of them than a row of phrases.
    private func splitPages() {
        let available = wordsWidth
        var starts = [0]
        var start = 0
        while start < words.count {
            var used: CGFloat = 0
            var index = start
            while index < words.count {
                let width = width(of: words[index], first: index == 0)
                if used + width > available, index > start { break }
                used += width
                index += 1
            }
            guard index < words.count else { break }
            starts.append(index)
            start = index
        }
        pageStarts = starts
        if page >= starts.count { page = max(0, starts.count - 1) }
    }

    private var pageRange: Range<Int> {
        let start = min(pageStarts[min(page, pageStarts.count - 1)], words.count)
        let end = page + 1 < pageStarts.count ? pageStarts[page + 1] : words.count
        return start..<min(max(start, end), words.count)
    }

    private func rebuild() {
        splitPages()
        let range = pageRange
        while slots.count < range.count, slots.count < 16 {
            let button = CandidateButton(type: .custom)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.addTarget(self, action: #selector(pickWord(_:)), for: .touchUpInside)
            slots.append(button)
            addSubview(button)
        }
        for (index, button) in slots.enumerated() {
            let wordIndex = range.lowerBound + index
            guard wordIndex < range.upperBound else {
                button.isHidden = true
                continue
            }
            let word = words[wordIndex]
            // The capsule marks what Space would put in: the run's leading word, never a
            // later page's first.
            let leads = wordIndex == 0
            button.isHidden = false
            button.tag = wordIndex
            button.setTitle(word, for: .normal)
            button.titleLabel?.font = leads ? Self.firstWordFont : Self.wordFont
            button.accessibilityLabel = word
            button.backgroundColor = leads ? palette.actionFill : .clear
            button.layer.cornerRadius = leads ? Self.capsuleRadius : 0
            button.setTitleColor(leads ? .white : palette.textBase, for: .normal)
            button.setTitleColor(leads ? UIColor(white: 1, alpha: 0.7) : palette.stripText, for: .highlighted)
        }
        previousButton.isHidden = page == 0
        nextButton.isHidden = page + 1 >= pageStarts.count
        setNeedsLayout()
    }

    @objc private func pickWord(_ sender: UIButton) {
        guard words.indices.contains(sender.tag) else { return }
        onPick?(words[sender.tag])
    }

    @objc private func turnForward() {
        guard page + 1 < pageStarts.count else { return }
        page += 1
        onPage?(true)
        rebuild()
    }

    @objc private func turnBack() {
        guard page > 0 else { return }
        page -= 1
        onPage?(false)
        rebuild()
    }

    /// Which page is showing.
    var currentPage: Int { page }

    /// Turns a page, forward or back.
    func turn(_ forward: Bool) {
        forward ? turnForward() : turnBack()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The bar is first shown before it is laid out: what a page holds follows its width,
        // so the words are split again once that is known.
        if splitWidth != bounds.width {
            splitWidth = bounds.width
            rebuild()
            return
        }
        let height = bounds.height
        // The pinyin's line takes what an 11 pt line needs; the words take the rest of the row.
        let band = min(14, max(12, height * 0.36))
        pinyinLabel.frame = CGRect(x: Self.inset, y: 0, width: max(0, bounds.width - 2 * Self.inset), height: band)
        let top = band
        let rowHeight = max(0, height - band)

        var x = Self.inset
        let limit = Self.inset + wordsWidth
        for (index, button) in slots.enumerated() where !button.isHidden {
            let wordIndex = pageRange.lowerBound + index
            guard words.indices.contains(wordIndex) else { continue }
            let width = width(of: words[wordIndex], first: wordIndex == 0)
            let room = max(0, limit - x)
            button.frame = CGRect(x: x, y: top + 0.5, width: min(width, room), height: max(0, rowHeight - 1))
            x += width
        }
        let trailing = bounds.width - Self.inset - Self.arrowCell
        previousButton.frame = CGRect(x: trailing, y: top, width: Self.arrowWidth, height: rowHeight)
        nextButton.frame = CGRect(x: trailing + Self.arrowWidth, y: top, width: Self.arrowWidth, height: rowHeight)
    }

    private func applyPalette() {
        pinyinLabel.attributedText = pinyinLine()
        previousButton.tintColor = palette.stripText
        nextButton.tintColor = palette.stripText
        rebuild()
    }
}

/// A word in the bar. It dims as a whole when pressed, so the capsule's fill dims with it.
private final class CandidateButton: UIButton {
    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }
}
