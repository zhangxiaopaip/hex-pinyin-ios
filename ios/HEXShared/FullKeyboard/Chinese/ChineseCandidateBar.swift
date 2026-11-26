import UIKit

/// 简体中文's candidate bar: the words the pinyin run spells, as Apple's Chinese keyboard
/// shows them, in place of the predictive strip while a run composes.
///
/// It pages: the first page holds the likeliest words, `›` brings the rest, `‹` goes back.
/// The bar sits exactly where the strip does (`KeyboardLayout.stripFrame`), so the Hex key
/// keeps its place and the keys never move.
@MainActor
final class ChineseCandidateBar: UIView {
    /// A word picked: the engine puts it in place of the run's letters.
    var onPick: ((String) -> Void)?
    /// A page turned.
    var onPage: ((_ forward: Bool) -> Void)?

    var palette = FullKeyboardPalette(isDark: false) {
        didSet { if palette.isDark != oldValue.isDark { applyPalette() } }
    }

    private var words: [String] = []
    private var page = 0
    private var generation = -1
    private var slots: [UIButton] = []
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    /// The pinyin the run has typed, at the bar's leading edge: the field shows the letters
    /// too, but here they read as what is being composed rather than as text already typed.
    private let bufferLabel = UILabel()
    private var buffer = ""
    /// The page size the words were last split for.
    private var pageSize = 0
    private let separatorLines = (0..<10).map { _ in UIView() }

    /// How much of the bar the pinyin keeps, so a long run never squeezes the words out.
    private var bufferWidth: CGFloat {
        guard !buffer.isEmpty else { return 0 }
        return min(104, max(56, bounds.width * 0.2))
    }

    /// How many words fit: about 40 pt a word, within what a thumb can hit.
    private var perPage: Int {
        let width = max(bounds.width - bufferWidth, 200)
        return min(Self.maxSlots, max(5, Int(width / 40)))
    }

    /// The most words a page holds, so the buttons exist before the bar has its width.
    private static let maxSlots = 9

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        bufferLabel.font = .systemFont(ofSize: 16)
        bufferLabel.lineBreakMode = .byTruncatingHead
        bufferLabel.isUserInteractionEnabled = false
        addSubview(bufferLabel)
        for line in separatorLines {
            line.isUserInteractionEnabled = false
            addSubview(line)
        }
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
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        button.setImage(image, for: .normal)
        button.tintColor = palette.stripText
        button.isHidden = true
    }

    /// The run's pinyin, its words, and whether the run is new (the bar then shows its first page).
    func show(buffer: String, words: [String], generation: Int) {
        if buffer != self.buffer {
            self.buffer = buffer
            bufferLabel.text = buffer.isEmpty
                ? nil
                : (PinyinDictionary.shared.isLoaded ? buffer : String(localized: "Dictionary missing"))
            bufferLabel.isHidden = buffer.isEmpty
            setNeedsLayout()
        }
        if generation != self.generation {
            self.generation = generation
            page = 0
        }
        if words != self.words {
            self.words = words
            page = 0
            rebuild()
        }
    }

    private var pages: Int {
        let size = perPage
        return max(1, (words.count + size - 1) / size)
    }

    /// One page's words.
    private var pageWords: [String] {
        let size = perPage
        let start = min(page * size, max(0, words.count))
        return Array(words[start..<min(start + size, words.count)])
    }

    private func rebuild() {
        let shown = pageWords
        // Every slot the widest page holds exists from the first refresh: the bar is first
        // shown before it is laid out, and a page must not lose the words it has room for now.
        while slots.count < Self.maxSlots {
            let button = UIButton(type: .custom)
            button.titleLabel?.font = .systemFont(ofSize: 17)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setTitleColor(palette.textBase, for: .normal)
            button.setTitleColor(palette.stripText, for: .highlighted)
            button.addTarget(self, action: #selector(pickWord(_:)), for: .touchUpInside)
            slots.append(button)
            addSubview(button)
        }
        for (index, button) in slots.enumerated() {
            let hasWord = index < shown.count
            button.isHidden = !hasWord
            if hasWord {
                button.setTitle(shown[index], for: .normal)
                button.accessibilityLabel = shown[index]
            }
        }
        previousButton.isHidden = page == 0
        nextButton.isHidden = page + 1 >= pages
        setNeedsLayout()
    }

    @objc private func pickWord(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        onPick?(title)
    }

    @objc private func turnForward() {
        guard page + 1 < pages else { return }
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

    /// Which page is showing, for the strip's own paging (◀ ▶ on the arrow keys).
    var currentPage: Int { page }

    func turn(_ forward: Bool) {
        forward ? turnForward() : turnBack()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The bar is first shown before it is laid out: the page it can hold follows its width
        // (and the pinyin's), so the words are split again once that is known.
        if pageSize != perPage {
            pageSize = perPage
            rebuild()
            return
        }
        let height = bounds.height
        let arrow: CGFloat = 18
        let inset: CGFloat = 6
        var x = inset
        let bufferWidth = self.bufferWidth
        bufferLabel.frame = CGRect(x: inset, y: 0, width: max(0, bufferWidth - 8), height: height)
        x += bufferWidth
        if !previousButton.isHidden {
            previousButton.frame = CGRect(x: x, y: 0, width: arrow, height: height)
            x += arrow
        }
        let trailingArrow = nextButton.isHidden ? 0 : arrow
        let available = max(0, bounds.width - x - inset - trailingArrow)
        let shown = pageWords
        let slot = shown.isEmpty ? 0 : available / CGFloat(shown.count)

        for (index, button) in slots.enumerated() where !button.isHidden {
            button.frame = CGRect(x: x + slot * CGFloat(index), y: 1, width: slot, height: height - 2)
        }
        if !nextButton.isHidden {
            nextButton.frame = CGRect(x: bounds.width - inset - arrow, y: 0, width: arrow, height: height)
        }

        // Dividers between the words, as Apple's candidate bar has.
        for (index, line) in separatorLines.enumerated() {
            guard index < shown.count - 1, slot > 0 else { line.isHidden = true; continue }
            line.isHidden = false
            line.frame = CGRect(x: x + slot * CGFloat(index + 1), y: height * 0.28, width: 1 / max(traitCollection.displayScale, 1), height: height * 0.44)
        }
    }

    private func applyPalette() {
        bufferLabel.textColor = palette.stripText
        for button in slots {
            button.setTitleColor(palette.textBase, for: .normal)
            button.setTitleColor(palette.stripText, for: .highlighted)
        }
        previousButton.tintColor = palette.stripText
        nextButton.tintColor = palette.stripText
        for line in separatorLines { line.backgroundColor = palette.separator }
    }
}
