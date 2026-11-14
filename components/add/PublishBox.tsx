"use client";

// The end of the add flow. Sign-in appears only here, and only when Publish is
// pressed; the draft stays saved while it happens. First-time posters also give
// the name shown on their drops and confirm they're 18 or older.

import { useEffect, useState } from "react";
import { SignIn } from "@/components/auth/SignIn";
import { useSession } from "@/components/auth/session";
import { inputClass, labelClass, primaryButton, secondaryButton } from "@/components/ui";
import { getProfile, getStanding, saveDrop, saveProfile, type Profile, type Standing } from "@/lib/drops/mine";
import type { Review } from "@/lib/drops/types";
import { findUpload } from "@/lib/upload/store";
import { uploadAsset } from "@/lib/upload/upload";
import { allProblems, draftToInput, type Draft, type Step } from "./draft";

export type Published = { id: string; review: Review };

const NAME_MAX = 40;

export function PublishBox({
  draft,
  onBack,
  onProblem,
  onUploaded,
  onPublished,
}: {
  draft: Draft;
  onBack: () => void;
  /** Go to a step that still needs something, and show what. */
  onProblem: (step: Step) => void;
  /** The photo or model is uploaded; keep its id so a retry doesn't upload it again. */
  onUploaded: (assetId: string) => void;
  onPublished: (result: Published) => void;
}) {
  const session = useSession();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const [askSignIn, setAskSignIn] = useState(false);
  const [profile, setProfile] = useState<{ userId: string; value: Profile | null } | null>(null);
  const [standing, setStanding] = useState<{ userId: string; value: Standing | null } | null>(null);
  const [name, setName] = useState<string | null>(null);
  const [adult, setAdult] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    getProfile(userId).then((value) => !cancelled && setProfile({ userId, value }));
    getStanding().then((value) => !cancelled && setStanding({ userId, value }));
    return () => {
      cancelled = true;
    };
  }, [userId]);

  // undefined while loading; null if it couldn't be read.
  const current = userId && profile?.userId === userId ? profile.value : undefined;
  const needsProfile = current !== undefined && !(current?.displayName && current.adultConfirmed);
  const suggested = session.status === "signed-in" ? session.user.suggestedName : null;
  const shownName = name ?? current?.displayName ?? suggested ?? "";
  // Signed out, or still loading: assume good standing, the usual case.
  const myStanding = (userId && standing?.userId === userId ? standing.value?.standing : null) ?? "good";

  async function publish() {
    setError(null);
    const found = allProblems(draft);
    if (found.length) return onProblem(found[0].step);
    if (!userId) return setAskSignIn(true);
    if (current === undefined) return;
    if (needsProfile && !shownName.trim()) return setError("Add the name shown on your drops.");
    if (needsProfile && !adult) return setError("Confirm you're 18 or older to publish.");

    if (!draft.placement) return onProblem(2);

    setBusy("Publishing…");
    if (needsProfile) {
      const failed = await saveProfile(userId, shownName);
      if (failed) {
        setBusy(null);
        return setError(failed);
      }
      setProfile({ userId, value: { displayName: shownName.trim(), adultConfirmed: true, isStaff: current?.isStaff ?? false } });
    }

    // A photo or model goes up first; the drop then points at it.
    let ready = draft;
    if (draft.upload && !draft.upload.assetId) {
      setBusy("Uploading…");
      const kept = draft.upload.localId ? await findUpload(draft.upload.localId) : null;
      if (!kept) {
        setBusy(null);
        return setError("The photo or model isn't on this device anymore. Choose it again in the first step.");
      }
      const uploaded = await uploadAsset(userId, kept);
      if ("error" in uploaded) {
        setBusy(null);
        return setError(uploaded.error);
      }
      onUploaded(uploaded.assetId);
      ready = { ...draft, upload: { ...draft.upload, assetId: uploaded.assetId } };
      setBusy("Publishing…");
    }

    const input = draftToInput(ready);
    if (!input) {
      setBusy(null);
      return onProblem(1);
    }
    const result = await saveDrop(input);
    setBusy(null);
    if ("error" in result) return setError(result.error);
    onPublished(result);
  }

  return (
    <>
      {session.status === "signed-out" && askSignIn && (
        <SignIn next="/add" lead="Sign in to publish. Your drop stays saved on this device while you do." />
      )}

      {userId && needsProfile && (
        <div className="flex flex-col gap-3">
          <label className={labelClass}>
            Name shown on your drops
            <input
              value={shownName}
              maxLength={NAME_MAX}
              autoComplete="nickname"
              onChange={(event) => setName(event.target.value)}
              className={inputClass}
            />
            <span className="text-xs font-normal text-muted">
              People see it on everything you add, like &quot;Object from Sam&quot;.
            </span>
          </label>
          <label className="flex min-h-11 cursor-pointer items-center gap-3 text-sm">
            <input type="checkbox" checked={adult} onChange={(event) => setAdult(event.target.checked)} className="size-5 accent-accent" />
            I&apos;m 18 or older
          </label>
        </div>
      )}

      {error && (
        <p role="alert" className="text-sm text-rejected">
          {error}
        </p>
      )}

      <div className="flex gap-2">
        <button type="button" onClick={onBack} className={`${secondaryButton} flex-1`}>
          Back
        </button>
        <button
          type="button"
          onClick={publish}
          disabled={busy !== null || session.status === "loading" || (userId !== null && current === undefined)}
          className={`${primaryButton} flex-[2]`}
        >
          {busy ?? (draft.editing ? "Save changes" : "Publish")}
        </button>
      </div>

      <p className="text-xs text-muted">
        {myStanding === "suspended"
          ? "Your account is suspended, so you can't publish."
          : draft.upload && !draft.upload.assetId
            ? "A person checks every photo and model before people can see it in the app, usually within a day."
            : myStanding === "review"
              ? "A person checks your drops for now, usually within a day. Until then only you can see it."
              : draft.editing
                ? "Your changes show in the app as soon as you save."
                : "It shows in the app as soon as you publish."}
      </p>
    </>
  );
}
