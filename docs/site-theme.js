(function () {
  const STORAGE_KEY = "asop-site-theme";
  const SYSTEM_QUERY = "(prefers-color-scheme: dark)";
  const allowedPreferences = new Set(["system", "light", "dark"]);
  const systemTheme = window.matchMedia(SYSTEM_QUERY);
  const darkStylesheet = document.querySelector("[data-dark-theme-stylesheet]");
  const lightThemeColor = document.querySelector('[data-theme-color="light"]');
  const darkThemeColor = document.querySelector('[data-theme-color="dark"]');
  let preference = readPreference();

  function readPreference() {
    try {
      const storedPreference = window.localStorage.getItem(STORAGE_KEY);
      return allowedPreferences.has(storedPreference) ? storedPreference : "system";
    } catch (_error) {
      return "system";
    }
  }

  function resolvedTheme() {
    if (preference === "system") {
      return systemTheme.matches ? "dark" : "light";
    }

    return preference;
  }

  function syncControls() {
    const resolved = resolvedTheme();
    const nextTheme = resolved === "dark" ? "light" : "dark";
    const label = `Switch to ${nextTheme} mode`;

    document.querySelectorAll("[data-theme-toggle]").forEach((toggle) => {
      toggle.dataset.currentTheme = resolved;
      toggle.setAttribute("aria-pressed", String(resolved === "dark"));
      toggle.setAttribute("aria-label", "Dark mode");
      toggle.setAttribute("title", label);
    });
  }

  function applyTheme() {
    const resolved = resolvedTheme();

    document.documentElement.dataset.theme = resolved;
    document.documentElement.dataset.themePreference = preference;

    if (darkStylesheet) {
      if (preference === "system") {
        darkStylesheet.media = SYSTEM_QUERY;
      } else {
        darkStylesheet.media = preference === "dark" ? "all" : "not all";
      }
    }

    if (lightThemeColor && darkThemeColor) {
      lightThemeColor.media = resolved === "light" ? "all" : "not all";
      darkThemeColor.media = resolved === "dark" ? "all" : "not all";
    }

    syncControls();
  }

  function savePreference() {
    try {
      if (preference === "system") {
        window.localStorage.removeItem(STORAGE_KEY);
      } else {
        window.localStorage.setItem(STORAGE_KEY, preference);
      }
    } catch (_error) {
      // The current page still changes when storage is unavailable.
    }
  }

  function chooseTheme(value) {
    if (!allowedPreferences.has(value)) {
      return;
    }

    preference = value;
    savePreference();
    applyTheme();
  }

  applyTheme();

  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll("[data-theme-toggle]").forEach((toggle) => {
      toggle.hidden = false;
      toggle.addEventListener("click", () => {
        chooseTheme(resolvedTheme() === "dark" ? "light" : "dark");
      });
    });

    syncControls();

    document.querySelectorAll("[data-nav-menu-toggle]").forEach((toggle) => {
      const navigationId = toggle.getAttribute("aria-controls");
      const navigation = navigationId ? document.getElementById(navigationId) : null;

      if (!navigation) {
        return;
      }

      const setMenuOpen = (isOpen, restoreFocus) => {
        navigation.classList.toggle("is-open", isOpen);
        toggle.setAttribute("aria-expanded", String(isOpen));
        toggle.setAttribute("aria-label", isOpen ? "Close menu" : "Open menu");
        toggle.setAttribute("title", isOpen ? "Close menu" : "Open menu");

        if (isOpen) {
          navigation.querySelector("a")?.focus();
        } else if (restoreFocus) {
          toggle.focus();
        }
      };

      toggle.hidden = false;
      toggle.addEventListener("click", () => {
        setMenuOpen(toggle.getAttribute("aria-expanded") !== "true", false);
      });

      navigation.querySelectorAll("a").forEach((link) => {
        link.addEventListener("click", () => setMenuOpen(false, false));
      });

      document.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && toggle.getAttribute("aria-expanded") === "true") {
          setMenuOpen(false, true);
        }
      });

      document.addEventListener("click", (event) => {
        if (
          toggle.getAttribute("aria-expanded") === "true" &&
          !toggle.contains(event.target) &&
          !navigation.contains(event.target)
        ) {
          setMenuOpen(false, false);
        }
      });

      const desktopNavigation = window.matchMedia("(min-width: 821px)");
      const handleNavigationWidthChange = () => setMenuOpen(false, false);

      if (typeof desktopNavigation.addEventListener === "function") {
        desktopNavigation.addEventListener("change", handleNavigationWidthChange);
      } else if (typeof desktopNavigation.addListener === "function") {
        desktopNavigation.addListener(handleNavigationWidthChange);
      }
    });
  });

  const handleSystemThemeChange = () => {
    if (preference === "system") {
      applyTheme();
    }
  };

  if (typeof systemTheme.addEventListener === "function") {
    systemTheme.addEventListener("change", handleSystemThemeChange);
  } else if (typeof systemTheme.addListener === "function") {
    systemTheme.addListener(handleSystemThemeChange);
  }

  window.addEventListener("storage", (event) => {
    if (event.key !== STORAGE_KEY) {
      return;
    }

    preference = readPreference();
    applyTheme();
  });
}());
