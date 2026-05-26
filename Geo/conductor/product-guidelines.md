# Product Guidelines: Geo

## Visual Identity
Geo adopts a **Refined Native** aesthetic. It is grounded in the macOS ecosystem but elevated with modern, minimalist touches to assert its premium quality.

### Design Principles
1.  **System Native Foundation:**
    -   Utilize macOS standard visual materials (NSVisualEffectView), vibrancy, and blur effects to blend seamlessly with the desktop environment.
    -   Adhere strictly to Apple's Human Interface Guidelines (HIG) for layout, spacing, and interaction patterns.
    -   Use SF Symbols as the primary iconography set for consistency and familiarity.

2.  **Modern Minimalist Elevation:**
    -   **Refined Palette:** While using system colors, employ "Geo Blue" (#0055FF) as the primary accent for brand-specific features to distinguish the application while remaining professional.
    -   **Clean Typography:** Stick to the system font (SF Pro) but use weight and tracking thoughtfully to create hierarchy without clutter.
    -   **Subtle Customization:** Introduce custom UI elements (e.g., title bar accessories) only where system components limit efficiency or aesthetic cohesion, ensuring they horizontally align with native macOS elements like traffic lights.

## Voice and Tone
Geo's communication style is adaptive, mirroring the user's workflow intensity.

### Primary Tone: Clever & Minimal
For general interactions, success states, and rapid feedback loops, the voice is short, punchy, and energetic.
-   *Example:* "Captured." instead of "Screen capture successful."
-   *Example:* "Ready." instead of "The system is ready for input."

### Secondary Tone: Professional & Precise
For settings, error messages, deep technical configurations, or AI-related explanations, the voice shifts to being exact and informative.
-   *Example:* "OCR failed: Image resolution too low for accurate text extraction."
-   *Example:* "API Key requires read/write permissions for block synchronization."

## User Interface (UI) Guidelines
-   **Whitespace & Readability:** Prioritize "breathing room" through generous line heights (1.6x) and ample margins (40pt) in editing environments. Use whitespace strategically to improve focus and readability.
-   **Motion:** Animations should be lightning-fast (non-distracting) and used only to convey state changes or spatial relationships (e.g., a block snapping into place).
-   **Dark Mode:** First-class support for Dark Mode is mandatory. The "Refined Native" aesthetic must look equally stunning in both light and dark appearances.

## Accessibility
-   Support dynamic type sizing where feasible within the block editor.
-   Ensure all custom controls have proper accessibility labels and roles.
-   Full keyboard navigation is a core requirement for the "Power User" audience.
