import Image from "next/image";
import { thumbnailFor } from "@/lib/drops/format";
import type { PublicDrop } from "@/lib/drops/types";

/** The drop's object on a soft square, for lists and cards. */
export function DropThumb({
  drop,
  className = "size-12",
  imageClassName = "size-[38px]",
  eager = false,
}: {
  drop: PublicDrop;
  className?: string;
  imageClassName?: string;
  /** Load at once, for a picture at the top of the screen. */
  eager?: boolean;
}) {
  const src = thumbnailFor(drop);
  return (
    <span className={`flex shrink-0 items-center justify-center rounded-[10px] bg-wash ${className}`}>
      {src && (
        <Image
          src={src}
          alt=""
          width={128}
          height={128}
          loading={eager ? "eager" : undefined}
          className={`object-contain ${imageClassName}`}
        />
      )}
    </span>
  );
}
