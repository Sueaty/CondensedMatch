# Project code style

Apply this style throughout the Swift code in this repository.

- Use four spaces for indentation and one statement per line. Do not use semicolons to combine statements.
- Expand view builders, control flow, and closures onto separate lines. Place each child view on its own line.
- In SwiftUI, write each chained view modifier on its own line, indented beneath the view or closing brace it modifies. Keep the start of the chain attached to its owning view so the target is clear.
- Write `Button` actions and `label` closures as multiline blocks when they contain a view, modifier, or more than one operation.
- Put the closing brace of a view or closure on its own line. Start its modifier chain on the following line.
- Separate distinct view sections and declarations with a blank line. Avoid trailing whitespace.
- Keep these edits formatting-only unless a behavior change is explicitly requested. Preserve existing accessibility identifiers, strings, and behavior.

Example:

```swift
Button {
    showDetails = true
} label: {
    Image(systemName: "info.circle")
        .font(.title3)
        .padding(11)
        .background(.white.opacity(0.7), in: Circle())
}
.accessibilityLabel("Details")
```
