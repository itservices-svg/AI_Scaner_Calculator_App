# HandWrite AI

Handwritten digit recognizer + calculator. Canvas par number likho, CNN (MNIST, 99.15% test accuracy, TFLite) digits pehchanta hai, operator buttons se calculate karo.

- Model: `assets/digit_model.tflite` (28x28 grayscale input)
- APK: Releases section mein (GitHub Actions se build hota hai, tag `v*` push par)

## Scan Calculator (camera)

Kaagaz par likhe numbers ki photo lo (ya gallery se chuno). App digits alag karti hai, CNN se parhti hai, numbers dikhati hai (galat ho to edit karo), phir Sum / Minus / Zarb / Taqseem / Average / Min / Max.
