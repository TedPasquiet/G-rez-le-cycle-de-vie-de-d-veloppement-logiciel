const path = require('path');

// ESLint est installé dans front/node_modules et sa config y réside :
// on l'exécute depuis front/ avec des chemins relatifs à ce dossier.
const eslintOnFront = (files) => {
  const rel = files
    .map((f) => path.relative(path.join(__dirname, 'front'), f))
    .join(' ');
  return `bash -c "cd front && npx eslint --fix ${rel}"`;
};

module.exports = {
  // Front — corrections ESLint puis mise en forme Prettier
  'front/**/*.{ts,html}': (files) => [
    eslintOnFront(files),
    `prettier --write ${files.join(' ')}`,
  ],
  'front/**/*.{css,scss,json}': 'prettier --write',

  // Back — Spotless reformate le code Java (tout le module ; les fichiers
  // indexés modifiés sont ré-indexés automatiquement par lint-staged).
  // Le wrapper Gradle vit dans back/, d'où le cd.
  'back/**/*.java': () => 'bash -c "cd back && ./gradlew spotlessApply"',

  // Documentation et configuration à la racine
  '*.{md,yml,yaml,json}': 'prettier --write',
};
