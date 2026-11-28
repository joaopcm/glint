# Lunetta

A native macOS app for taking screenshots and screen recordings and sharing them: a card, an annotation editor,
compression, copy, upload.

## Language

### Capturing

**Capture**:
A screenshot Lunetta saves as one PNG: area, window, full screen, or scrolling.
_Avoid_: Snap, shot

**Recording**:
A screen video Lunetta saves as a movie file.
_Avoid_: Capture (when meaning video)

**Scrolling capture**:
A capture built from many frames of one area while its content scrolls, joined into one tall PNG.
_Avoid_: Long screenshot, scrolling screenshot, full-page capture

**Tall capture**:
A capture more portrait than the card or the screen showing it, whatever mode made it.

### On screen

**Stage**:
An area kept on screen with a panel of controls while the user acts inside it: the **recording stage** (set up a
recording) or the **scrolling stage** (scroll and finish a scrolling capture).
_Avoid_: Bare "stage" when it isn't clear which one

**Capture chrome**:
Lunetta's own windows that frame a capture rather than belong in it (selection overlay, stages, recording HUD); they
are kept out of every capture.
_Avoid_: Bare "chrome" (collides with the Chrome browser)

**Card**:
The thumbnail panel a new capture or recording appears in at a screen corner.
_Avoid_: Thumbnail, toast, overlay

## Relationships

- A **scrolling capture** happens on exactly one **scrolling stage** and produces one **capture**
- A **scrolling capture** is usually a **tall capture**; any **tall capture** shows its top on the **card**
- Every **stage** window is **capture chrome**

## Example dialogue

> **Dev:** "When the user presses Done on the **scrolling stage**, is the result a **recording**?"
> **Domain expert:** "No, a **capture**: one PNG. It goes to the **card** like any other, and since it's a **tall
> capture**, the card shows its top with the height badge."

## Flagged ambiguities

- "stage" meant only the recording stage until scrolling capture: resolved, always say **recording stage** or
  **scrolling stage**.
- "chrome" means Lunetta's framing windows here, not the browser: resolved, say **capture chrome**.
