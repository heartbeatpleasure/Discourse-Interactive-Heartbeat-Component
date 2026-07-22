import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";
import { themePrefix } from "virtual:theme";

function enabled(value, fallback = true) {
  if (value === null || value === undefined || value === "") {
    return fallback;
  }

  return ![false, "false", 0, "0"].includes(value);
}

export default apiInitializer("1.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  const pluginEnabled = siteSettings?.interactive_heartbeat_enabled === true;
  const navEnabled = siteSettings?.interactive_heartbeat_nav_enabled !== false;
  const themeSettings = typeof settings === "undefined" ? {} : settings;
  const themeEnabled = enabled(themeSettings.show_nav_item, true);

  if (!pluginEnabled) {
    return;
  }

  api.registerNotificationTypeRenderer(
    "interactive_heartbeat",
    (NotificationTypeBase) =>
      class extends NotificationTypeBase {
        get linkHref() {
          return this.notification?.data?.url || "/interactive-heartbeat";
        }

        get linkTitle() {
          return i18n(
            themePrefix("interactive_heartbeat.notifications.title"),
          );
        }

        get icon() {
          return "heart";
        }

        get label() {
          return (
            this.notification?.data?.display_username ||
            i18n(themePrefix("interactive_heartbeat.notifications.fallback_actor"))
          );
        }

        get description() {
          const event = this.notification?.data?.event || "invitation";
          const key = `interactive_heartbeat.notifications.${event}`;
          const modeKey = this.notification?.data?.mode;
          const mode = modeKey
            ? i18n(themePrefix(`interactive_heartbeat.modes.${modeKey}.label`))
            : "";
          return i18n(themePrefix(key), { mode });
        }
      },
  );

  if (!navEnabled || !themeEnabled) {
    return;
  }

  const customText = String(themeSettings.nav_item_text || "").trim();
  const label =
    customText || i18n(themePrefix("interactive_heartbeat.nav_title"));

  api.addNavigationBarItem({
    name: "interactive-heartbeat",
    displayName: label,
    href: "/interactive-heartbeat",
    title: label,
  });
});
