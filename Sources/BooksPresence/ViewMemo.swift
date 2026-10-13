import Foundation

/// One derived value a view keeps across redraws. It is a plain reference that SwiftUI does not
/// observe, so reading or filling it never invalidates the view: a body asks for the value under
/// its current inputs and only pays to rebuild it when those inputs changed. Hold it in `@State`.
final class ViewMemo<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?

    func value(for key: Key, _ make: () -> Value) -> Value {
        if let value, self.key == key { return value }
        let made = make()
        self.key = key
        value = made
        return made
    }
}
