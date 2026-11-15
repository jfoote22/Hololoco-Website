"use client";

// The add flow: What, Where and When. It never leaves the map: the drop
// appears on the map as soon as it has a place, and sign-in waits until Publish.

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { SignIn } from "@/components/auth/SignIn";
import { useSession } from "@/components/auth/session";
import { useMap } from "@/components/map/MapProvider";
import { SheetHeight } from "@/components/map/SheetHeight";
import { SearchBox } from "@/components/SearchBox";
import { choiceCard, inputClass, labelClass, primaryButton, secondaryButton, textButton } from "@/components/ui";
import { categories, offerKinds } from "@/lib/drops/categories";
import { limits } from "@/lib/drops/limits";
import { listMyDrops } from "@/lib/drops/mine";
import { allowed, getMyPlan, type Allowed } from "@/lib/plans";
import { library, libraryObject } from "@/lib/library/objects";
import { forgetUpload } from "@/lib/upload/store";
import type { DropType } from "@/lib/drops/types";
import {
  clearDraft,
  draftFromDrop,
  loadDraft,
  newDraft,
  PLACEMENT_DEFAULTS,
  problems,
  storeDraft,
  type Draft,
  type DraftOffer,
  type Step,
} from "./draft";
import { LookPicker } from "./LookPicker";
import { PublishBox, type Published } from "./PublishBox";
import { useUploadPreview, type UploadPreview } from "./useUploadPreview";
import { WhenStep } from "./WhenStep";

const STEP_NAMES: Record<Step, string> = { 1: "What", 2: "Where", 3: "When" };
const stepName = (step: Step, type: DropType) => (step === 3 && type === "offer" ? "When and how rare" : STEP_NAMES[step]);

const TYPES: { type: DropType; name: string; line: string }[] = [
  { type: "offer", name: "Offer", line: "A deal people collect in the app and redeem at your business." },
  { type: "object", name: "Object", line: "Something to find at a place, with a short caption." },
  { type: "message", name: "Message", line: "A note for people who come by." },
];

const subscribeToNothing = () => () => {};

/** Reads ?edit=<id>; a different drop gets a fresh flow. */
export function AddFlowRoute() {
  const editId = useSearchParams().get("edit");
  // The draft is in this browser's storage, which the server can't see. Drawing the
  // flow only once the page runs here keeps the two from disagreeing about the step.
  const inBrowser = useSyncExternalStore(subscribeToNothing, () => true, () => false);
  if (!inBrowser) return <p className="text-sm text-muted">Loading…</p>;
  return <AddFlow key={editId ?? "new"} editId={editId} />;
}

function AddFlow({ editId }: { editId: string | null }) {
  const router = useRouter();
  const session = useSession();
  const { engine, status, setDraft: setDraftPin, reload } = useMap();
  const heading = useRef<HTMLHeadingElement>(null);

  const [draft, setDraft] = useState<Draft>(() => {
    const saved = loadDraft();
    if (editId) return saved?.editing === editId ? saved : { ...newDraft(), editing: editId };
    return saved && !saved.editing ? saved : newDraft();
  });
  // An edit is ready once its drop has loaded, or when resuming a saved edit.
  const [editReady, setEditReady] = useState(() => !editId || Boolean(draft.placement));
  const [editMissing, setEditMissing] = useState(false);
  const [tried, setTried] = useState(false);

  const update = (change: Partial<Draft>) => setDraft((d) => ({ ...d, ...change }));
  const preview = useUploadPreview(draft.upload);
  const userId = session.status === "signed-in" ? session.user.id : null;
  // What the person's plan allows. Signed out, nothing is held back until Publish.
  const [can, setCan] = useState<Allowed>({ offers: true, models: true, events: false });

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    getMyPlan().then((plan) => {
      if (cancelled || !plan) return;
      const now = allowed(plan);
      setCan(now);
      // A new drop starts as an offer; without offers, start with a message instead.
      if (!now.offers)
        setDraft((d) =>
          !d.editing && d.type === "offer"
            ? { ...d, type: "message", objectId: d.objectId === library[0]?.id ? "note" : d.objectId }
            : d,
        );
    });
    return () => {
      cancelled = true;
    };
  }, [userId]);

  // Load the drop being edited.
  useEffect(() => {
    if (!editId || editReady || !userId) return;
    let cancelled = false;
    listMyDrops()
      .then((drops) => {
        if (cancelled) return;
        const drop = drops.find((d) => d.id === editId);
        if (drop) {
          setDraft(draftFromDrop(drop));
          setEditReady(true);
        } else {
          setEditMissing(true);
        }
      })
      .catch(() => !cancelled && setEditMissing(true));
    return () => {
      cancelled = true;
    };
  }, [editId, editReady, userId]);

  // Keep the draft in this browser as it changes.
  useEffect(() => {
    if (editReady) storeDraft(draft);
  }, [draft, editReady]);

  // Show the draft on the map once it has a place.
  useEffect(() => {
    if (!draft.placement) return setDraftPin(null);
    const object = draft.upload ? null : libraryObject(draft.objectId);
    setDraftPin({
      id: draft.editing ?? "draft",
      type: draft.type,
      title: "Your drop",
      placement: draft.placement,
      thumbnail: draft.upload ? preview?.thumbnail : object?.thumbnail,
      modelUrl: draft.upload ? preview?.model : object?.model,
    });
  }, [draft.placement, draft.objectId, draft.upload, preview, draft.type, draft.editing, setDraftPin]);
  useEffect(() => () => setDraftPin(null), [setDraftPin]);

  // Dragging the pin moves the drop.
  useEffect(() => {
    if (!engine) return;
    return engine.onDraftMove((at) => setDraft((d) => (d.placement ? { ...d, placement: { ...d.placement, ...at } } : d)));
  }, [engine]);

  // On the Where step, a tap on the map puts the drop there.
  useEffect(() => {
    if (!engine || draft.step !== 2) return;
    return engine.onMapTap((at) =>
      setDraft((d) => ({ ...d, placement: { ...PLACEMENT_DEFAULTS, ...d.placement, ...at } })),
    );
  }, [engine, draft.step]);

  function goTo(step: Step) {
    setTried(false);
    if (step === 2 && engine) {
      const zoom = Math.max(engine.getZoom(), 17);
      if (draft.placement) {
        engine.flyTo({ center: draft.placement, zoom });
      } else {
        const center = engine.getCenter();
        update({ placement: { ...PLACEMENT_DEFAULTS, ...center } });
        engine.flyTo({ center, zoom });
      }
    }
    update({ step });
    heading.current?.focus();
  }

  function next() {
    if (problems(draft, draft.step).length) return setTried(true);
    goTo((draft.step + 1) as Step);
  }

  function startOver() {
    if (draft.upload?.localId) void forgetUpload(draft.upload.localId);
    clearDraft();
    setTried(false);
    setDraft(newDraft());
    if (editId) router.push("/add");
  }

  function onPublished({ id }: Published) {
    const editing = draft.editing;
    if (draft.upload?.localId) void forgetUpload(draft.upload.localId);
    clearDraft();
    // This screen stays alive in the background, so reset it for next time.
    setDraft(newDraft());
    reload();
    router.push(editing ? `/?saved=${id}` : `/?added=${id}`);
  }

  if (editId && !editReady) {
    return (
      <>
        <SheetHeight size="half" />
        <h1 className="text-[22px] font-bold">Edit your drop</h1>
        {session.status === "signed-out" ? (
          <SignIn next={`/add?edit=${editId}`} lead="Sign in to edit your drop." />
        ) : editMissing ? (
          <p className="text-sm text-muted">That drop isn&apos;t one of yours, or it&apos;s been deleted.</p>
        ) : (
          <p className="text-sm text-muted">Loading your drop…</p>
        )}
      </>
    );
  }

  const stepProblems = tried ? problems(draft, draft.step) : [];

  return (
    <>
      <SheetHeight size={draft.step === 2 ? "half" : "full"} />

      <div className="flex flex-col gap-1">
        <h1 ref={heading} tabIndex={-1} className="text-[22px] font-bold outline-none">
          {draft.editing ? "Edit your drop" : "Add to the map"}
        </h1>
        <div className="flex items-center justify-between gap-2">
          <p className="text-sm text-muted">
            Step {draft.step} of 3: {stepName(draft.step, draft.type)}
          </p>
          <button type="button" onClick={startOver} className={textButton}>
            {draft.editing ? "Cancel" : "Start over"}
          </button>
        </div>
        <ol className="flex gap-1.5" aria-hidden="true">
          {([1, 2, 3] as Step[]).map((s) => (
            <li key={s} className={`h-1 flex-1 rounded-full ${s <= draft.step ? "bg-accent" : "bg-line"}`} />
          ))}
        </ol>
      </div>

      {draft.step === 1 && <WhatStep draft={draft} update={update} preview={preview} can={can} />}
      {draft.step === 2 && (
        <WhereStep draft={draft} update={update} mapReady={status === "ready"} mapUnavailable={status === "unavailable"} />
      )}
      {draft.step === 3 && <WhenStep draft={draft} update={update} />}

      {stepProblems.length > 0 && (
        <ul role="alert" className="flex flex-col gap-1 rounded-lg bg-wash px-3 py-2 text-sm text-rejected">
          {stepProblems.map((p) => (
            <li key={p}>{p}</li>
          ))}
        </ul>
      )}

      <div className="sticky -bottom-4 -mx-4 -mb-4 mt-auto flex flex-col gap-3 border-t border-line bg-surface px-4 pt-3 pb-4 max-md:pb-3">
        {draft.step === 3 ? (
          <PublishBox
            draft={draft}
            onBack={() => goTo(2)}
            onProblem={(step) => {
              goTo(step);
              setTried(true);
            }}
            onUploaded={(assetId) =>
              setDraft((d) => (d.upload ? { ...d, upload: { ...d.upload, assetId } } : d))
            }
            onPublished={onPublished}
          />
        ) : (
          <div className="flex gap-2">
            {draft.step > 1 && (
              <button type="button" onClick={() => goTo((draft.step - 1) as Step)} className={`${secondaryButton} flex-1`}>
                Back
              </button>
            )}
            <button
              type="button"
              onClick={next}
              disabled={draft.step === 2 && status !== "ready"}
              className={`${primaryButton} flex-[2]`}
            >
              Next: {stepName((draft.step + 1) as Step, draft.type)}
            </button>
          </div>
        )}
      </div>
    </>
  );
}

type StepProps = { draft: Draft; update: (change: Partial<Draft>) => void };

function WhatStep({ draft, update, preview, can }: StepProps & { preview: UploadPreview | null; can: Allowed }) {
  const titleLeft = limits.titleMaxChars - draft.title.length;
  const descriptionLeft = limits.descriptionMaxChars - draft.description.length;
  // An offer being edited stays editable even if the plan has changed since.
  const offerLocked = !can.offers && !(draft.editing && draft.type === "offer");
  return (
    <div className="flex flex-col gap-4">
      <fieldset className="flex flex-col gap-2">
        <legend className="mb-2 text-sm font-semibold">What is it?</legend>
        {TYPES.map(({ type, name, line }) => (
          <label key={type} className={`${choiceCard} ${type === "offer" && offerLocked ? "cursor-default opacity-70" : ""}`}>
            <input
              type="radio"
              name="type"
              checked={draft.type === type}
              disabled={type === "offer" && offerLocked}
              onChange={() =>
                update({
                  type,
                  // A speech bubble suits a message, unless they already chose something else.
                  objectId: type === "message" && draft.objectId === library[0]?.id ? "note" : draft.objectId,
                })
              }
              className="mt-1 accent-accent"
            />
            <span className="text-sm">
              <b className="block">{name}</b>
              <span className="text-muted">{line}</span>
              {type === "offer" && offerLocked && (
                <span className="mt-1 block text-[13px]">
                  Offers come with the Business plan.{" "}
                  <Link href="/plan" className="font-medium text-accent hover:underline">
                    See plans
                  </Link>
                </span>
              )}
            </span>
          </label>
        ))}
      </fieldset>

      {draft.type === "offer" && <OfferFields offer={draft.offer} update={(offer) => update({ offer: { ...draft.offer, ...offer } })} />}

      <label className={labelClass}>
        {draft.type === "offer" ? "Title people see" : "Title"}
        <input
          value={draft.title}
          maxLength={limits.titleMaxChars}
          onChange={(event) => update({ title: event.target.value })}
          className={inputClass}
          aria-describedby="title-left"
        />
        <span id="title-left" className="text-xs font-normal text-muted">
          {titleLeft} characters left
        </span>
      </label>

      <label className={labelClass}>
        {draft.type === "message" ? "Message" : draft.type === "offer" ? "More about it (optional)" : "Caption (optional)"}
        <textarea
          value={draft.description}
          maxLength={limits.descriptionMaxChars}
          rows={3}
          onChange={(event) => update({ description: event.target.value })}
          className={`${inputClass} py-2 leading-normal`}
          aria-describedby="description-left"
        />
        <span id="description-left" className="text-xs font-normal text-muted">
          {descriptionLeft} characters left
        </span>
      </label>

      <LookPicker draft={draft} update={update} preview={preview} canModels={can.models} />
    </div>
  );
}

/** What people get, how many, and the terms. */
function OfferFields({ offer, update }: { offer: DraftOffer; update: (change: Partial<DraftOffer>) => void }) {
  const whole = (value: string) => (value === "" ? 0 : Math.floor(Number(value)));
  return (
    <div className="flex flex-col gap-4 rounded-lg border border-line p-3">
      <label className={labelClass}>
        Kind of offer
        <select
          value={offer.kind}
          onChange={(event) => update({ kind: event.target.value as DraftOffer["kind"] })}
          className={inputClass}
        >
          {offerKinds.map((k) => (
            <option key={k.id} value={k.id}>
              {k.name}
            </option>
          ))}
        </select>
        <span className="text-xs font-normal text-muted">{offerKinds.find((k) => k.id === offer.kind)?.hint}</span>
      </label>

      <label className={labelClass}>
        What do people get?
        <input
          value={offer.savings}
          maxLength={limits.offerSavingsMaxChars}
          placeholder="Buy one coffee, get one free"
          onChange={(event) => update({ savings: event.target.value })}
          className={inputClass}
        />
        <span className="text-xs font-normal text-muted">Say it plainly. This is what people see first.</span>
      </label>

      <div className="grid grid-cols-2 gap-3">
        <label className={labelClass}>
          How many in all
          <input
            type="number"
            inputMode="numeric"
            min={1}
            max={limits.offerMaxQuantity}
            value={offer.quantity || ""}
            onChange={(event) => update({ quantity: whole(event.target.value) })}
            className={inputClass}
          />
        </label>
        <label className={labelClass}>
          Each person can claim
          <input
            type="number"
            inputMode="numeric"
            min={1}
            max={limits.offerMaxPerPerson}
            value={offer.perPerson || ""}
            onChange={(event) => update({ perPerson: whole(event.target.value) })}
            className={inputClass}
          />
        </label>
      </div>

      <label className={labelClass}>
        Terms (optional)
        <textarea
          value={offer.terms}
          maxLength={limits.offerTermsMaxChars}
          rows={2}
          placeholder="Dine-in only. Not with other offers."
          onChange={(event) => update({ terms: event.target.value })}
          className={`${inputClass} py-2 leading-normal`}
        />
      </label>

      <label className={labelClass}>
        What kind of business is it?
        <select value={offer.category} onChange={(event) => update({ category: event.target.value })} className={inputClass}>
          {categories.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
        <span className="text-xs font-normal text-muted">
          Quests made of one kind of business get a theme, like a coffee crawl.
        </span>
      </label>

      <label className="flex min-h-11 cursor-pointer items-start gap-3 text-sm">
        <input
          type="checkbox"
          checked={offer.tradeable}
          onChange={(event) => update({ tradeable: event.target.checked })}
          className="mt-1 accent-accent"
        />
        <span>
          <b className="block font-medium">People can trade it</b>
          <span className="text-muted">
            They can swap it with other players or leave it on the map for someone else. Whoever holds it can redeem it.
          </span>
        </span>
      </label>
    </div>
  );
}

function WhereStep({
  draft,
  update,
  mapReady,
  mapUnavailable,
}: StepProps & { mapReady: boolean; mapUnavailable: boolean }) {
  const { engine } = useMap();
  const placement = draft.placement;

  if (mapUnavailable) {
    return (
      <p className="rounded-lg bg-wash px-3 py-2.5 text-sm text-muted">
        The 3D map couldn&apos;t load in this browser, so a drop can&apos;t be placed from here. Try another browser or
        device.
      </p>
    );
  }

  const setPlacement = (change: Partial<NonNullable<Draft["placement"]>>) =>
    placement && update({ placement: { ...placement, ...change } });

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm">Tap the map where it goes, or drag its pin. You can also search for the place first.</p>

      <SearchBox onPlace={(place) => update({ placement: { ...PLACEMENT_DEFAULTS, ...placement, ...place.center } })} />

      <button
        type="button"
        disabled={!mapReady}
        onClick={() => engine && update({ placement: { ...PLACEMENT_DEFAULTS, ...placement, ...engine.getCenter() } })}
        className={`${secondaryButton} min-h-11 text-sm`}
      >
        Move it to the middle of the map
      </button>

      {placement && (
        <div className="flex flex-col gap-4">
          <Slider
            label="Size"
            value={placement.size}
            min={0.5}
            max={limits.maxSizeMetres}
            step={0.5}
            text={`${placement.size} m across`}
            onChange={(size) => setPlacement({ size })}
          />
          <Slider
            label="Height"
            value={placement.height}
            min={0}
            max={limits.maxHeightMetres}
            step={1}
            text={placement.height === 0 ? "On the ground" : `${placement.height} m above the ground`}
            onChange={(height) => setPlacement({ height })}
          />
          <Slider
            label="Turn"
            value={placement.turn}
            min={0}
            max={355}
            step={5}
            text={`${placement.turn}°`}
            onChange={(turn) => setPlacement({ turn })}
          />
          <p className="text-xs text-muted">
            The map draws objects larger than life so people can spot them from down the street.
          </p>
        </div>
      )}
    </div>
  );
}

function Slider({
  label,
  value,
  min,
  max,
  step,
  text,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  text: string;
  onChange: (value: number) => void;
}) {
  return (
    <label className={labelClass}>
      <span className="flex justify-between">
        {label}
        <span className="font-normal text-muted">{text}</span>
      </span>
      <input
        type="range"
        value={value}
        min={min}
        max={max}
        step={step}
        aria-valuetext={text}
        onChange={(event) => onChange(Number(event.target.value))}
        className="h-11 w-full accent-accent"
      />
    </label>
  );
}
