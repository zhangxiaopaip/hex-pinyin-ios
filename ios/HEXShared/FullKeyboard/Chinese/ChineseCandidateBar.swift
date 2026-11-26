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
    private let separatorLines = (0..<10).map { _ in UIView() }

    /// How many words fit: about 40 pt a word, within what a thumb can hit.
    private var perPage: Int {
        let width = max(bounds.width, 200)
        return min(9, max(5, Int(width / 40)))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
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

    required init?(coder: NSCoder) { nil }

    private func configureArrow(_ button: UIButton, symbol: String) {
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        button.setImage(image, for: .normal)
        button.tintColor = palette.stripText
        button.isHidden = true
    }

    /// The run's words, and whether the run is new (the bar then shows its first page).
    func show(words: [String], generation: Int) {
        if generation != self.generation {
            self.generation = generation
            page = 0
        }
        if words != self.words {
            self.words = words
            page = min(page, max(0, pages - 1))
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
        while slots.count < shown.count {
            let button = UIButton(type: .custom)
            button.titleLabel?.font = .systemFont(ofSize: 17)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
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
        let height = bounds.height
        let arrow: CGFloat = 18
        let inset: CGFloat = 6
        var x = inset
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
        for button in slots {
            button.setTitleColor(palette.textBase, for: .normal)
            button.setTitleColor(palette.stripText, for: .highlighted)
        }
        previousButton.tintColor = palette.stripText
        nextButton.tintColor = palette.stripText
        for line in separatorLines { line.backgroundColor = palette.separator }
    }
}
