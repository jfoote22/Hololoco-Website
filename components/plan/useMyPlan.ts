"use client";

// The signed-in person's plan: undefined while loading, null when signed out or
// when this database doesn't have plans yet.

import { useEffect, useState } from "react";
import { useSession } from "@/components/auth/session";
import { getMyPlan, type MyPlan } from "@/lib/plans";

export function useMyPlan(version = 0): MyPlan | null | undefined {
  const session = useSession();
  const userId = session.status === "signed-in" ? session.user.id : null;
  const [loaded, setLoaded] = useState<{ key: string; plan: MyPlan | null } | null>(null);
  const key = `${userId}:${version}`;

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    getMyPlan().then((plan) => !cancelled && setLoaded({ key: `${userId}:${version}`, plan }));
    return () => {
      cancelled = true;
    };
  }, [userId, version]);

  if (session.status === "signed-out") return null;
  if (!userId || loaded?.key !== key) return undefined;
  return loaded.plan;
}
