// Theme handling (light / dark / system).
//
// The *initial* data-theme is set by a tiny synchronous inline snippet in
// root.html.heex so there is no flash of the wrong theme before this bundled
// module loads. This module owns the event listeners that react to user
// toggles, cross-tab changes, and OS preference changes.

const systemTheme = () =>
  matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"

export const setTheme = (theme) => {
  if (theme === "system") {
    localStorage.removeItem("phx:theme")
    document.documentElement.setAttribute("data-theme", systemTheme())
    document.documentElement.setAttribute("data-theme-source", "system")
  } else {
    localStorage.setItem("phx:theme", theme)
    document.documentElement.setAttribute("data-theme", theme)
    document.documentElement.setAttribute("data-theme-source", "user")
  }
}

export function initTheme() {
  // Safety net: if the inline boot snippet was missing for any reason, set the
  // initial theme now from the stored preference (or system default).
  if (!document.documentElement.hasAttribute("data-theme")) {
    setTheme(localStorage.getItem("phx:theme") || "system")
  }

  // Sync theme across browser tabs.
  window.addEventListener(
    "storage",
    (e) => e.key === "phx:theme" && setTheme(e.newValue || "system")
  )

  // Theme toggle buttons dispatch this event (see Layouts.theme_toggle/1).
  window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme))

  // Follow the OS preference while in "system" mode.
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    if (document.documentElement.getAttribute("data-theme-source") === "system") {
      document.documentElement.setAttribute("data-theme", systemTheme())
    }
  })
}
