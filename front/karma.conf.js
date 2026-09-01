// Karma configuration file, see link for more information
// https://karma-runner.github.io/1.0/config/configuration-file.html

module.exports = function (config) {
  config.set({
    basePath: "",
    frameworks: ["jasmine", "@angular-devkit/build-angular"],
    plugins: [
      require("karma-jasmine"),
      require("karma-chrome-launcher"),
      require("karma-jasmine-html-reporter"),
      require("karma-coverage"),
      require("@angular-devkit/build-angular/plugins/karma"),
    ],
    client: {
      jasmine: {
        // you can add configuration options for Jasmine here
        // the possible options are listed at https://jasmine.github.io/api/edge/Configuration.html
        // for example, you can disable the random execution with `random: false`
        // or set a specific seed with `seed: 4321`
      },
      clearContext: false, // leave Jasmine Spec Runner output visible in browser
    },
    jasmineHtmlReporter: {
      suppressAll: true, // removes the duplicated traces
    },
    coverageReporter: {
      dir: require("path").join(__dirname, "./coverage/microcrm"),
      subdir: ".",
      // lcovonly : format consommé par SonarCloud (sonar.javascript.lcov.reportPaths).
      reporters: [
        { type: "html" },
        { type: "text-summary" },
        { type: "lcovonly" },
      ],
      // Seuils bloquants : en dessous, `ng test --code-coverage` sort en erreur
      // et le job test-front échoue. Le pendant côté back est
      // jacocoTestCoverageVerification (back/build.gradle).
      //
      // Ils ne s'appliquent qu'avec --code-coverage, donc au lancement de la
      // CI ; un `ng test` local reste rapide et sans contrainte.
      //
      // `branches` est plus bas que le reste, et c'est volontaire : les
      // garde-fous des composants (`if (id === undefined) return`) créent des
      // branches nombreuses et peu nourrissantes. Le chiffre est calé juste
      // sous la valeur réelle pour détecter une baisse, pas pour afficher un
      // objectif qu'on abaisserait à la première gêne.
      check: {
        global: {
          statements: 90,
          lines: 90,
          functions: 90,
          branches: 80,
        },
      },
    },
    reporters: ["progress", "kjhtml"],
    browsers: ["ChromeHeadlessNoSandbox", "ChromeHeadless", "Chrome"],
    customLaunchers: {
      ChromeHeadlessNoSandbox: {
        base: "ChromeHeadless",
        flags: ["--no-sandbox"],
      },
    },
    restartOnFileChange: true,
  });
};
