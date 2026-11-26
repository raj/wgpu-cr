# Plan d'implémentation — Couche objet (`WGPU::Device#create_buffer`, etc.)

> Objectif « Coming next » du README : une API orientée objet au-dessus de la FFI,
> à la wgpu-py — `device.create_buffer(...)` au lieu de `WGPU.create_buffer(device, ...)`.

---

## 1. Objectif

Exposer les 23 handles wgpu comme des objets Crystal qui **possèdent** leur handle
C et le relâchent automatiquement :

```crystal
require "wgpu"

instance = WGPU::Instance.new
adapter  = instance.request_adapter
device   = adapter.request_device

storage = device.create_buffer(size: bytes, usage: LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc)
queue.write_buffer(storage, input)
shader  = device.create_shader_module(WGSL)
pipeline = device.create_compute_pipeline(shader)
bind_group = device.create_bind_group(layout, [{0_u32, storage, bytes}])
queue.dispatch_workgroups(pipeline, bind_group, 4)
output = queue.read_buffer(storage, bytes)

device.release; adapter.release; instance.release
```

L'API statique `WGPU.*` existante reste **inchangée** (pas de breaking change) ;
elle déléguera à la couche objet en phase 4 pour éviter la duplication de la
logique d'attente synchrone.

---

## 2. Décisions de conception

### 2.1 Nommage

| FFI (`LibWGPU`)      | Objet (`WGPU`)     |
|----------------------|--------------------|
| `LibWGPU::Device`    | `WGPU::Device`     |
| `LibWGPU::Buffer`    | `WGPU::Buffer`     |
| …                    | …                  |

Aucune collision : les handles sont dans le namespace `LibWGPU` (alias `Void*`),
les classes dans `WGPU`. **Règle** : dans `module WGPU`, toujours qualifier
`LibWGPU::X` dans les restrictions de type (sinon `Device` résout vers la
nouvelle classe).

On garde le préfixe `LibWGPU::` pour les enums/bitflags (`BufferUsage`, etc.)
des signatures publiques — elles viennent directement du header et sont déjà
documentées.

> **Écart (phase 1)** : la classe de base s'appelle `WGPU::GPUObject(H)` et
> non `WGPU::Object` : dans `module WGPU`, un `WGPU::Object` masquerait
> `::Object` pour tout le code du module. Elle est générique sur le type du
> handle (`Buffer < GPUObject(LibWGPU::Buffer)`), ce qui type `#to_unsafe`.

### 2.2 Classe, pas struct

Classes allouées GC (identité mutable, héritage, `finalize` possible). Chaque
classe stocke son handle **typé** (`@handle : LibWGPU::Buffer`) et expose :

- `#to_unsafe` → handle typé, pour l'interop avec la FFI et l'API statique actuelle ;
- `#released?`, `#release` (idempotent), `#finalize` (filet de sécurité GC) ;
- `#to_s` → `WGPU::Buffer(0x…, label: "storage")` pour le débogage.

### 2.3 Ownership / ref-counting

- Les fonctions `create_*`, `get_queue`, `*_get_bind_group_layout`,
  `texture_create_view`, `begin_*_pass` retournent une référence **possédée**
  (+1). Le wrapper est propriétaire : `#release` appelle le `*_release` FFI
  correspondant.
- `#release` est **idempotent** (flag `@released`) — double release inoffensif.
- `#finalize` relâche si pas déjà fait. ⚠️ Ne doit **jamais** lever ; guard
  obligatoire.
- Le relâchement dans n'importe quel ordre est sûr : chaque handle est
  ref-compté indépendamment côté wgpu (un buffer libéré après le device reste
  valide, il détient une forte référence sur le device en interne).
- **Références parents côté Crystal** : `Adapter` garde `@instance`,
  `Device` garde `@adapter`, les objets créés gardent `@device`. Empêche le GC
  de finaliser le parent (donc de relâcher le handle C) avant les enfants.
  Pas besoin de `wgpuXxxAddRef` pour ça.
- **Jamais de référence Crystal parent → enfant** (vérifié dans la stdlib :
  Crystal enregistre les finaliseurs Boehm en mode *ordonné*
  (`GC_register_finalizer_ignore_self`) ; un cycle entre objets finalisables
  n'est **jamais** collecté). Seule exception : `Device` met en cache sa
  `Queue` ; la `Queue` ne référence donc pas l'objet `Device`, mais garde son
  propre `+1` sur le handle C du device (`wgpuDeviceAddRef`) et l'`Instance`
  pour le pumping. `device.release` relâche aussi la queue ; le finaliseur
  du device, lui, ne cascade pas (la queue peut encore être utilisée).
- **Un finaliseur ne doit ni lever ni allouer** : allouer de la mémoire GC
  depuis un finaliseur Boehm bloque le process (vérifié). D'où
  `#finalize → release_once` (non virtuel) et des `release_handle` réduits
  à l'appel FFI.
- L'enchaînement `buffer → device → adapter → instance` est indispensable :
  le *pumping* d'événements (`instance_process_events` dans `wait_until`)
  est nécessaire pour les opérations asynchrones synchronisées (map, request).
  Le `Buffer` doit donc pouvoir retrouver l'`Instance` via sa chaîne.

### 2.4 Le problème `Void*` et la release par type

Tous les handles sont des alias `Void*` : Crystal ne peut ni surcharger ni
dispatcher sur le type d'alias (constat déjà documenté dans `api.cr` pour
`release_pass`). Solution : **méthode abstraite virtuelle** sur la classe de base
— le dispatch se fait sur la *classe wrapper*, pas sur l'alias :

```crystal
abstract class WGPU::Object
  @released = false

  def release : Nil
    return if @released
    @released = true
    release_handle
  end

  def finalize
    release # ne doit jamais lever
  end

  private abstract def release_handle : Nil
end
```

Chaque classe concrète implémente `release_handle` (ex. `LibWGPU.buffer_release(@handle)`).

### 2.5 Synchronicité

Même modèle que l'API actuelle : asynchrone C → **synchrone** Crystal via la
boucle `wait_until` (poll `wgpuInstanceProcessEvents` — `wgpuInstanceWaitAny`
est un stub qui aborte dans wgpu-native v29). Le helper est partagé
(voir 2.6) et les timeouts par défaut restent 5 s, paramétrables.

### 2.6 Factorisation des internes

Extraire les helpers communs de `api.cr` dans un module interne
`WGPU::Internal` (`wait_until`, `string_view`, `empty_string_view`, `null`,
`view_to_s`), `extend self`/`private` — **sans changer** les signatures
publiques de `WGPU` (qui continuent de déléguer). Une seule source de vérité
pour la logique d'attente et les conversions.

### 2.7 Descripteurs

Pas de types `WGPU::BufferDescriptor` dédiés pour la v1 : les méthodes prennent
des **arguments nommés** (comme les helpers statiques actuels), avec les mêmes
défauts (`label: nil`, `mapped_at_creation: false`…). Réévaluer des structs
d'options Crystal seulement si une méthode dépasse ~6 paramètres
(ex. `create_render_pipeline`, voir phase 3).

---

## 3. Structure de fichiers

```
src/wgpu.cr                    # + require "./wgpu/objects/**"
src/wgpu/api.cr                # inchangé en phases 1–3 ; délègue en phase 4
src/wgpu/internal.cr           # NOUVEAU : wait_until, StringView helpers, null
src/wgpu/objects/
  object.cr                    # WGPU::Object (base : release/finalize/to_unsafe)
  instance.cr                  # Instance
  adapter.cr                   # Adapter
  device.cr                    # Device (+ raccourcis dispatch/read/write_buffer)
  queue.cr                     # Queue (write_buffer, read_buffer, submit, …)
  buffer.cr                    # Buffer (+ mapping synchrone)
  texture.cr                   # Texture, TextureView
  sampler.cr                   # Sampler
  shader_module.cr             # ShaderModule
  pipeline.cr                  # ComputePipeline, RenderPipeline, PipelineLayout,
                               # BindGroupLayout (getters + release)
  bind_group.cr                # BindGroup
  encoder.cr                   # CommandEncoder, ComputePassEncoder,
                               # RenderPassEncoder, RenderBundleEncoder
  surface.cr                   # Surface
  query_set.cr                 # QuerySet
spec/
  objects_spec.cr              # compute headless via l'API objet, RAII, double-release
examples/
  compute_oo.cr                # le même exemple ×2 en syntaxe objet
```

---

## 4. Phases

### Phase 0 — Refactor des internes (pré-requis, ~½ journée) ✅

- Créer `src/wgpu/internal.cr` : déplacer/copier `wait_until` (public dans
  `Internal` mais privé pour l'utilisateur), `string_view`, `null_string_view`,
  `empty_string_view`, `view_to_s`, `null`.
- `api.cr` conserve ses signatures actuelles en déléguant à `Internal`.
- `crystal spec` vert : zéro changement de comportement.

### Phase 1 — Le squelette : `GPUObject`, `Instance`, `Adapter`, `Device`, `Queue` ✅

| Classe | Méthodes | FFI couvertes |
|---|---|---|
| `Instance` | `.new`, `#request_adapter(power_preference:, compatible_surface:, timeout:)`, `#process_events`, `#create_surface` (phase 3), `#has_wgsl_language_feature?` | `wgpuCreateInstance`, `wgpuInstanceRequestAdapter`, `wgpuInstanceProcessEvents`, `wgpuInstanceHasWGSLLanguageFeature` |
| `Adapter` | `#request_device(timeout:, **callbacks)`, `#info`, `#limits`, `#features`, `#has_feature?` | `wgpuAdapterRequestDevice`, `wgpuAdapterGetInfo/GetLimits/GetFeatures/HasFeature` |
| `Device` | `#queue`, `#has_feature?`, `#limits`, `#features`, `#set_label`, `#adapter` | `wgpuDeviceGetQueue`, `wgpuDeviceHasFeature/GetLimits/GetFeatures/SetLabel` |
| `Queue` | `#write_buffer(buffer, data, offset:)`, `#submit(command_buffers)`, `#set_label` | `wgpuQueueWriteBuffer`, `wgpuQueueSubmit`, `wgpuQueueSetLabel` |

- Les formes bloc (`instance.request_adapter { |a| … }`) relâchent en sortie
  de bloc, comme l'API statique actuelle.
- Sur `Device` : les usines `create_*` sont posées mais *stubs de phase 1*
  (buffer + shader module seulement, pour tester le chaînage).
- Specs : `spec/objects_spec.cr` — instance/adapter/device en blocs, compute
  minimal `device → queue.write_buffer → queue.read_buffer`.

**Livrable** : `WGPU::Instance.new → … → device` en syntaxe objet, releases
automatiques, tests verts.

> **Réalisé** : comme prévu, sauf `#set_label` et `#has_wgsl_language_feature?`,
> non exposés (stubs qui abortent, cf. §6) : le label se passe à la création.
> En plus : `GPUObject#use { }` (forme bloc générique), garde « used after
> release » (`WGPU::Error` au lieu d'un use-after-free), `Device#adapter_info`,
> `Buffer#size/usage/destroy`, `Queue#read_buffer` (via `WGPU.read_buffer`).
> Specs : `spec/objects_spec.cr` (8 exemples, dont finalisation GC réelle).

### Phase 2 — Les ressources créées par le device

| Classe | Méthodes principales | FFI couvertes |
|---|---|---|
| `Buffer` | `#size`, `#usage`, `#map_state`, `#map_read/map_write(timeout:)`, `#const_mapped_range(size, offset:)` → `Bytes`, `#mapped_range` → `Slice(UInt8)`, `#read_mapped/write_mapped`, `#unmap`, `#destroy` | `wgpuBufferGetSize/GetUsage/GetMapState/MapAsync/GetConstMappedRange/GetMappedRange/ReadMappedRange/WriteMappedRange/Unmap/Destroy` |
| `ShaderModule` | `#set_label` (compilation info plus tard) | `wgpuShaderModuleSetLabel` |
| `Texture` / `TextureView` | `#create_view(format:, dimension:, …)`, getters (`#width`, `#height`, `#format`, …), `#destroy` | `wgpuTextureCreateView/Get*/Destroy` |
| `Sampler` | (descripteur via args nommés) | `wgpuDeviceCreateSampler` |
| `BindGroupLayout` / `PipelineLayout` | créés par `device.create_bind_group_layout(entries)`, `device.create_pipeline_layout(layouts)` | `wgpuDeviceCreateBindGroupLayout/CreatePipelineLayout` |
| `BindGroup` | `device.create_bind_group(layout, entries)` — v1 : buffers (`{binding, buffer, size}`) ; extension textures/samplers ensuite | `wgpuDeviceCreateBindGroup` |
| `ComputePipeline` / `RenderPipeline` | `device.create_compute_pipeline(module:, entry_point:, layout:, label:)` (layout NULL = auto) ; `#bind_group_layout(group)` | `wgpuDeviceCreateComputePipeline`, `wgpuComputePipelineGetBindGroupLayout` (+ render : phase 3) |
| `CommandEncoder` | `device.create_command_encoder`, `#copy_buffer_to_buffer`, `#copy_buffer_to_texture`, `#clear_buffer`, `#finish` (passes : phase 3) | `wgpuDeviceCreateCommandEncoder`, `wgpuCommandEncoderCopy*/ClearBuffer/Finish` |

- Raccourcis de parité avec l'API statique (sur `Device`/`Queue`) :
  - `device.create_buffer_with_data(data, usage:, label:)`
  - `device.dispatch(pipeline, bind_group, x, y, z)` (encode+submit en un appel)
  - `queue.read_buffer(buffer, size)` → `Bytes` (staging MapRead + copy + map
    bloquant + unmap, comme `WGPU.read_buffer` actuel)
  - `device.read_buffer(buffer, size)` / `device.write_buffer(buffer, data)`
    en alias vers la queue.
- Le mapping `Buffer#map_read` remonte l'`Instance` via `@device` pour pumper.

**Livrable** : `spec/objects_spec.cr` rejoue le test compute « ×2 » **entièrement
en syntaxe objet** (miroir du spec existant, garde la régression de l'API
statique).

### Phase 3 — Encoders, passes, surface

| Classe | Méthodes | FFI |
|---|---|---|
| `ComputePassEncoder` | `#set_pipeline`, `#set_bind_group`, `#dispatch_workgroups`, `#end` | `wgpuComputePassEncoder*` |
| `RenderPassEncoder` | `#set_pipeline`, `#set_bind_group`, `#set_vertex_buffer`, `#set_index_buffer`, `#draw`, `#draw_indexed`, `#set_viewport`, `#set_scissor_rect`, `#end` | `wgpuRenderPassEncoder*` |
| `RenderPassDescriptor` | struct Crystal conviviale (`color_attachments`, `depth_stencil`, `clear values`…), construite en `LibWGPU::RenderPassDescriptor` avant l'appel | — |
| `RenderPipeline` | `device.create_render_pipeline(**desc)` — gros descripteur : introduire alors un struct d'options Crystal si > 6 args nommés | `wgpuDeviceCreateRenderPipeline` |
| `RenderBundleEncoder` / `RenderBundle` | `device.create_render_bundle_encoder`, `#finish` | `wgpuRenderBundle*` |
| `Surface` | `instance.create_surface(**platform_handles)`, `#configure(device, format:, usage:)`, `#current_texture`, `#present`, `#unconfigure`, `#capabilities` | `wgpuInstanceCreateSurface`, `wgpuSurface*` |

- La chaîne triangle GLFW (`examples/triangle.cr`) peut servir de banc d'essai ;
  la glue GLFW reste dans `examples/lib_glfw.cr`, le wrapper accepte les
  handles natifs bruts.

**Livrable** : render d'un triangle via l'API objet (exemple ou spec optionnel
headless via `WGPU_FRAMES`).

### Phase 4 — Consolidation

1. **Délégation** : ~~réécrire les helpers statiques pour appeler la couche
   objet~~. *Revu en phase 1* : c'est la couche objet qui appelle les helpers
   statiques (`WGPU.request_adapter`, `WGPU.create_buffer`, `WGPU.read_buffer`…)
   avec ses handles, ce qui donne déjà une seule implémentation sans inverser
   les dépendances. Il ne reste qu'à vérifier, en fin de phase 3, qu'aucune
   logique n'est dupliquée entre les deux couches.
2. **Exemples** : `examples/compute_oo.cr` (nouveau) ; migrer
   `compute_wrapped.cr` vers l'objet et le renommer plus tard.
3. **Docs** : README (section « Object layer », tableau avant/après),
   doc-strings sur chaque classe/méthode publique.
4. Optionnel (post-plan) : `push/pop_error_scope`, `create_compute_pipeline_async`,
   `shader_module.compilation_info`, `queue.on_submitted_work_done`,
   `device.destroy`.

---

## 5. Tests

Dans `spec/objects_spec.cr` (tous headless, même schéma que l'existant) :

1. **Chaînage et releases en blocs** : `Instance.new { … request_adapter { … } }`.
2. **Compute ×2 en API objet** : miroir du spec statique — régression croisée.
3. **`to_unsafe` interop** : passer `buffer.to_unsafe` à `WGPU.dispatch`
   (API statique) — les deux couches coexistent.
4. **Double release** : `buf.release; buf.release` — idempotent, pas de crash.
5. **Finalize-safety** : créer un objet, perdre la référence, `GC.collect`,
   aucune erreur (le release est passé au finalizer).
6. **Mapping** : `buffer.map_read` + `const_mapped_range` sur un staging buffer.
7. **Timeout** : request avec timeout minuscule → `WGPU::Error` (le chemin
   `PENDING_TIMEOUT_RESULTS` reste couvert).
8. ABI guards existants : inchangés (`spec/wgpu_spec.cr` intact).

---

## 6. Risques & points d'attention

| Risque | Mitigation |
|---|---|
| `#finalize` appelé par le GC pendant une allocation → ne jamais y lever | flag `@released`, `release_handle` pur (pas de vérification NULL + raise) |
| Ordre de release croisé (enfant après parent) | sûr par design (ref-count wgpu indépendant) ; conserver les refs parents côté Crystal pour éviter un `finalize` prématuré du parent |
| Handles = alias `Void*` → pas d'overload possible | dispatch par classe wrapper (`release_handle` abstrait), jamais sur le type d'alias |
| Ambiguïté de noms `WGPU::Buffer` vs `LibWGPU::Buffer` dans `module WGPU` | qualifier systématiquement `LibWGPU::X` dans les restrictions |
| `wait_until` partagé entre deux couches | Phase 0 : une seule implémentation dans `WGPU::Internal` |
| `wgpuInstanceWaitAny` = stub qui aborte (v29) | continuer le polling `process_events` ; note dans la doc |
| Lifetime des `StringView` (pas de copie par `WGPU.string_view`) | même discipline qu'aujourd'hui : la String reste vivante pendant l'appel, wgpu copie à la création |
| `get_*` parfois +1 (queue, bind group layout) parfois pas | vérifier au cas par cas (webgpu.h : ces deux-là sont possédés, déjà traités dans `api.cr`) ; en cas de doute, `AddRef` défensif |
| Descripteur render pipeline énorme | struct d'options Crystal dédiée en phase 3 seulement |
| Stubs `unimplemented!()` de wgpu-native v29 : abort du process, impossible à rattraper (vérifié : tous les `wgpu*SetLabel`, `wgpuDeviceGetAdapterInfo`, `wgpuInstanceGetWGSLLanguageFeatures`, `wgpuInstanceHasWGSLLanguageFeature`, en plus de `wgpuInstanceWaitAny` et `wgpuHasInstanceFeature`) | ne jamais les appeler depuis la couche objet : label fixé à la création seulement, `Device#adapter_info` lu via l'`Adapter`, pas de requêtes WGSL. Sonder chaque nouvelle FFI avant de l'exposer |
| Cycle de références Crystal → objets jamais finalisés | pas de référence parent → enfant (cf. 2.3) |
| Callback de log wgpu (`set_log_stderr`) qui alloue une `String` s'il est déclenché pendant un release depuis un finaliseur → blocage | non observé (aucun log émis pendant les release, même en `Trace`) ; si besoin, différer les release du finaliseur vers une file pré-allouée |
| CI/GPU requis pour les specs | même approche que le spec actuel (compute headless), déjà en place dans le workflow |

---

## 7. Checklist de validation

- [ ] `crystal spec` vert (anciens + nouveaux specs)
- [ ] `crystal run examples/compute_oo.cr` → résultat ×2 correct
- [ ] Aucun `*_release` à écrire à la main dans l'exemple objet (cleanup
      automatique ou blocs)
- [ ] Double-release et finalize-safety testés
- [ ] API statique inchangée : les specs existants passent sans modification
- [ ] README mis à jour (« Coming next » → « ✅ Object layer »)
- [ ] `crystal tool format` propre, `crystal build --warnings-as-errors` (si
      activé dans la CI) vert
