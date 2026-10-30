# Island

**Une Dynamic Island pour l'encoche du MacBook. Quatre choses, bien faites. Elle ne recouvre jamais la barre des menus.**

<p align="center"><img src="docs/hero.png" width="600" alt="Island affiche la pochette et un spectre audio en direct de part et d'autre de l'encoche, avec le titre du nouveau morceau qui descend dessous"></p>

<p align="center"><a href="https://github.com/firegranger/island/releases/latest/download/Island.zip"><b>Télécharger</b></a> · gratuit et open source · macOS 15+ · MacBook avec encoche · <a href="README.md">English version</a></p>

---

## Pourquoi une app d'encoche de plus ?

Les apps d'encoche sont séduisantes jusqu'à ce qu'on s'en serve. Elles débordent sur la barre des menus, masquent menus et icônes, et s'encombrent de fonctions dont personne n'a besoin : étagère à fichiers, AirDrop, presse-papiers, calendrier, widgets… Et la plupart sont payantes.

Island prend le contre-pied.

### Elle ne recouvre jamais la barre des menus

Island mesure en continu la place libre de chaque côté de l'encoche : les menus de l'app active (y compris ceux que macOS envoie à droite de l'encoche quand une app en a trop) et chaque icône d'état. Puis elle choisit la première disposition qui tient :

**De la place des deux côtés :** pochette à gauche, spectre à droite, comme sur iPhone.
<img src="docs/placement-wings.png" alt="Island de part et d'autre de l'encoche, avec de la place autour">

**Encombré à gauche :** tout passe à droite.
<img src="docs/placement-right.png" alt="Les menus de l'app arrivent jusqu'à l'encoche : Island n'utilise que la droite">

**Encombré des deux côtés** (ici, les menus *Window* et *Help* de l'app ont été repoussés au-delà de l'encoche) : Island descend sous l'encoche, sans dépasser sa largeur.
<img src="docs/placement-below.png" alt="Des menus des deux côtés de l'encoche : Island affiche le titre sous l'encoche">

Quand on change d'app, elle se réorganise en une seconde ou deux.

### Quatre fonctions, rien d'autre

- **Musique en cours** (Musique, Spotify, navigateurs…) : pochette et spectre audio en direct, teinté aux couleurs de la pochette. Au changement de morceau, le titre et l'artiste descendent quelques secondes. Après une pause, Island reste visible encore quelques secondes avant de s'effacer.
- **Volume** et **luminosité** : remplace l'indicateur de macOS.
- **Notifications** *(expérimental)* : elles descendent de l'encoche.

Pas de fenêtre de réglages, pas d'icône dans le Dock, pas de compte.

<table><tr>
<td><img src="docs/volume.png" alt="Indicateur de volume de part et d'autre de l'encoche"></td>
<td><img src="docs/notification.png" alt="Une notification qui descend de l'encoche"></td>
</tr></table>

### Fluide et discrète

- **Invisible au repos.** Island se cache entièrement derrière l'encoche et en reprend la forme exacte : bords évasés en haut, coins arrondis en bas. Quand elle se replie, on dirait l'encoche qui reprend sa taille.
- **Des animations souples.** Island change de forme avec des ressorts, comme sur iPhone. Le contenu apparaît dans un flou une fois la forme ouverte, et s'efface avant qu'elle se referme.
- **Le curseur disparaît dans l'encoche,** comme s'il passait derrière. Au survol, l'îlot gonfle légèrement, avec un petit retour haptique.
- **Seulement là où il y a une encoche.** En recopie vers un projecteur, dans une définition 16:9 ou Mac fermé, Island se met en retrait et macOS reprend les touches volume et luminosité. Avec un écran externe, Island reste sur l'écran du MacBook.
- **Rien ne sort du Mac.** Pas de réseau, pas de statistiques. Le spectre est calculé à la volée, sans rien enregistrer.

## Gestes

| Geste | Effet |
|---|---|
| Survol de l'encoche | L'îlot gonfle légèrement, avec un petit retour haptique |
| Clic | Lecture / pause |
| Glisser à deux doigts sur l'encoche | Doigts vers la gauche : morceau suivant ; vers la droite : précédent |
| Clic sur une notification | Ouvre l'app concernée |
| ⌥⇧ + touches volume/luminosité | Crans plus fins |
| Clic droit | Ouverture à la session, autorisations, Quitter |

## Installer

1. [Télécharge Island.zip](https://github.com/firegranger/island/releases/latest/download/Island.zip), décompresse-le et place **Island** dans le dossier Applications.
2. Ouvre-la. Island n'est pas notariée (il faudrait un compte développeur Apple payant), donc macOS refuse de l'ouvrir la première fois. Va dans **Réglages Système › Confidentialité et sécurité**, descends en bas et clique sur **Ouvrir quand même**.
   Ou, dans le Terminal :
   ```bash
   xattr -dr com.apple.quarantine /Applications/Island.app
   ```
3. Accorde les autorisations que tu veux (voir ci-dessous), puis fais un clic droit sur l'encoche › **Ouvrir à l'ouverture de session**.

### Autorisations

Toutes se trouvent dans **Réglages Système › Confidentialité et sécurité**.

| Autorisation | Pour | Sans elle |
|---|---|---|
| **Accessibilité** | Les touches volume/luminosité, et la mesure de la place libre dans la barre des menus | macOS garde son indicateur ; l'îlot reste toujours sous l'encoche |
| **Enregistrement audio système** | Le spectre. Le son est analysé à la volée, jamais enregistré. | Le spectre est simplement animé |
| **Accès complet au disque** | Les notifications : macOS n'offre aucune API pour lire celles des autres apps, donc Island lit la base du Centre de notifications, en lecture seule | Pas de notifications |

Pour ne pas voir chaque notification en double : **Réglages Système › Notifications**, choisis l'app et mets son style d'alerte sur **Aucun**.

## Compiler

Les Command Line Tools suffisent ; Xcode n'est pas nécessaire.

```bash
git clone https://github.com/firegranger/island.git && cd island
./build.sh install
```

Le script compile, signe, copie l'app dans `/Applications` et la lance. S'il trouve un certificat *Apple Development*, il s'en sert, et les autorisations restent valables d'une compilation à l'autre. Sinon, l'app est signée ad hoc. `./build.sh dist` produit le zip publié dans les versions.

## Sous le capot

Swift natif (SwiftUI + AppKit), sans dépendance.

- `IslandController` : la fenêtre sur l'encoche, le survol, le glisser et le curseur. Les clics traversent la fenêtre partout hors de l'îlot.
- `IslandModel` : ce qui est affiché, et où.
- `IslandView` : la forme et toutes les animations (`Motion`).
- `MenuBarScanner` : la place libre dans la barre des menus, via l'API d'Accessibilité.
- `AudioSpectrum` : le spectre (Core Audio + FFT).
- `SystemControls` : les touches (event tap), CoreAudio et DisplayServices.
- `NowPlaying` + `Bridge/` : depuis macOS 15.4, MediaRemote (la musique en cours) n'est accessible qu'aux binaires Apple. Un petit dylib est donc chargé dans `/usr/bin/perl`, qui transmet les infos en JSON.
- `NotificationWatcher` : lit la base du Centre de notifications.

## Limites

- Plusieurs fonctions reposent sur des API ou des fichiers privés de macOS (musique en cours, luminosité, notifications). Une mise à jour de macOS peut les casser.
- Les notifications sont encore expérimentales.
- Testée sur un MacBook Pro 14" sous macOS 27.

## Licence

[MIT](LICENSE)
