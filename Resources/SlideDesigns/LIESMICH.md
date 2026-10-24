# Folienhintergründe für Presenter Studio

Jedes Design ist **eine CSS-Datei**. Presenter Studio liest beim Öffnen des
Hintergrund-Menüs alle `.css`-Dateien aus diesem Ordner und zeigt sie neben den
eingebauten Designs an. Eine Datei mit dem Namen eines eingebauten Designs
(z. B. `aurora.css`) ersetzt dieses.

## Kopf der Datei

```css
/*
 * @name Mein Design
 * @beschreibung Ein Satz, der das Design beschreibt
 * @text hell            hell = helle Schrift, dunkel = dunkle Schrift
 * @text-titel hell      optional, je Folienart: titel, kapitel, folie
 * @akzent #7CF0D0       Farbe für Links und Hervorhebungen im Text
 */
```

## Die Bühne

Das Design zeichnet auf eine Seite im Format 16:9:

```html
<body class="titel | kapitel | folie">
  <div class="e e1"></div> … <div class="e e6"></div>
</body>
```

- `body` trägt die Art der Folie: `titel` (Text mittig), `kapitel` (Text links,
  senkrecht mittig) oder `folie` (Text oben links). Inhaltsfolien sollten
  ruhig sein, damit der Text gut lesbar bleibt.
- Sechs leere Ebenen `.e1` bis `.e6` liegen über die ganze Fläche
  (`position: absolute; inset: 0`). Jede hat dazu `::before` und `::after`.
- Größen in `vw`, `vh` oder `vmin` wachsen mit der Folie mit.
- Animationen laufen nur in der Präsentation; im Editor stehen sie still
  (`html.still`) und zeigen ihren Anfang. `html.live` gilt während der
  Präsentation. Ein Design mit `@keyframes` steht im Menü unter „Bewegt“.
- Für eine nahtlose, ruhige Bewegung: `alternate` (hin und zurück) oder eine
  Ebene, die um genau eine Kachelbreite wandert (siehe `wellen.css`). Bewege
  am besten mit `transform`, das bleibt auch im Vollbild flüssig.
- Der Text der Folie beginnt etwa 6,4 % vom linken und rechten und 8,4 % vom
  oberen Rand.
