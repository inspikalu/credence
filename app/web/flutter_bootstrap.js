{{flutter_js}}
{{flutter_build_config}}

// Load CanvasKit and the fallback font from this server instead of a CDN, so
// the page has no third-party runtime dependencies (see fonts/fallback/).
const credenceEngineConfig = {
  canvasKitBaseUrl: "canvaskit/",
  fontFallbackBaseUrl: "fonts/fallback/",
};

_flutter.loader.load({
  config: credenceEngineConfig,
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine(credenceEngineConfig);
    await appRunner.runApp();
    const loading = document.getElementById("credence-loading");
    if (loading) {
      loading.classList.add("done");
      setTimeout(function () { loading.remove(); }, 250);
    }
  },
});
