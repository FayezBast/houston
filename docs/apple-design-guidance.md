# Apple design guidance for Houston

Research checked against Apple primary sources on September 13, 2026. These are design recommendations for Houston's existing native macOS app, which targets macOS 14 and later. They are not claims of an Apple affiliation or a native Dynamic Island integration.

## The camera housing is an exclusion area

Apple requires layouts to respect display safe areas and explicitly advises against placing content within a Mac's camera housing. `NSScreen.safeAreaInsets` describes the unobscured screen region; `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` describe additional safe areas beside the housing in global screen coordinates. The auxiliary rectangles can be absent. [Layout](https://developer.apple.com/design/human-interface-guidelines/layout), [NSScreen.safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets), [NSScreen.auxiliaryTopLeftArea](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea)

Application to Houston:

- Derive the exclusion width and center from the gap between the auxiliary rectangles. Treat the top inset as camera geometry only when there is a valid exclusion gap; avoid fixed device dimensions.
- Keep compact status in the two visible wings. Place navigation, titles, interactive controls, and expanded content below the camera band.
- Use a detached capsule inside the usable screen on displays without a housing. Clamp expanded size and horizontal reach to the available display while preserving the exclusion area's alignment.
- Verify scaled displays, different display origins, a side Dock, a small external display, and reconnection. These cases follow from Apple's requirement to adapt to display and context changes. [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

## Borrow the interaction model, with correct platform boundaries

Apple's Live Activities present current information and quick related actions. On iPhone, compact leading and trailing views form one cohesive status around the camera; a touch-and-hold reveals expanded information. ActivityKit manages the lifecycle, while a widget extension provides the interface. [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)

Current macOS supports Live Activities originating on a nearby iPhone in its menu bar. This does not turn a custom Mac `NSPanel` into a system Dynamic Island. Houston's existing AppKit panel remains an app-owned interface; the useful design analogy is progressive disclosure. [macOS Live Activities](https://developer.apple.com/macos/), [Live Activities essentials](https://developer.apple.com/videos/play/wwdc2026/223/)

Application to Houston: keep compact status quiet and legible; use a short peek for a meaningful event; reserve full pages for deliberate expansion. Maintain the same status identity through these states. Give keyboard users an equivalent way to open the panel, move between pages, and dismiss it. Preserve focus during background refreshes; Apple advises against moving focus without user interaction. [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection)

## Give every page one clear hierarchy

Apple recommends placing important content early in reading order and aligning components to communicate organization. Use one consistent page header, then the most useful reading, then supporting rows or settings. This is a Houston layout recommendation derived from those principles. [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

Use SF Pro through the system font APIs, primarily regular and medium weights with semibold emphasis. Apple's macOS defaults are 13 pt body text and a 10 pt minimum. Built-in text styles help maintain hierarchy; SF Symbols align with system text weights and sizes. macOS does not provide iOS-style Dynamic Type. Houston should therefore keep useful text comfortably readable without assuming mobile text scaling will fix a dense layout. [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)

Keep monospaced digits for readings that change, use color to identify meaningful status and selected actions, and give icons clear accessible names. Prefer consistent groups of rows and native buttons, pickers, and toggles over many unrelated card treatments. Standard framework controls adopt the current platform appearance. [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)

## Materials clarify structure

Apple places Liquid Glass in the controls and navigation layer, advises against using it throughout content, and recommends applying it sparingly. Standard materials serve content backgrounds. On macOS, choose a semantic `NSVisualEffectView` material and blending mode for the component's role. Color and opacity are not stable properties of a system material: test the result against different backgrounds and appearances. [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)

Application to Houston: retain a black camera band, separate the expanded page surface from navigation, and use quiet grouped fills for readings and settings. Use semantic foreground colors in the page body; fixed white belongs only on a reliably dark surface. Reserve saturated accents for selected controls, provider identity, and status that needs attention. [Color](https://developer.apple.com/design/human-interface-guidelines/color)

## Accessibility changes the presentation

Reduce Motion should remove spatial motion triggers, including scaling, spinning, and decorative ongoing movement. Replacing a spring with a slower ease curve still moves the interface. Apple's suggested alternatives for meaningful transitions include dissolves or highlight fades. For Houston, change panel geometry immediately under Reduce Motion and retain only brief opacity or color transitions where useful. [Reduced Motion evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria)

Test Increase Contrast, Reduce Transparency, keyboard input, and VoiceOver. Increased contrast should retain visible boundaries and text hierarchy; reduced transparency should provide a legible, more opaque surface. Expose state in text or accessible values as well as color. Check all pages with these settings, not just the compact island. [Testing system accessibility features](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app)

## Review targets

- Compact, peek, and expanded states on both notched and plain displays.
- Every page in light and dark appearance, including empty and error states.
- Readable labels and measurements at narrow widths without clipping controls.
- Stable keyboard focus and a visible selected page.
- Reduce Motion without shape morphs, slides, scale effects, or decorative pulses.
- Legible content over bright and dark desktop backgrounds with both normal and increased contrast.

These targets are a Houston-specific verification plan derived from the guidance above; they do not claim testing has already been completed.
