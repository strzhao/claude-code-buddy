import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import StatusBadge from "@/components/StatusBadge";

describe("StatusBadge", () => {
  it("should render pending status", () => {
    render(<StatusBadge status="pending" />);
    expect(screen.getByText("pending")).toBeDefined();
  });

  it("should render approved status", () => {
    render(<StatusBadge status="approved" />);
    expect(screen.getByText("approved")).toBeDefined();
  });

  it("should render rejected status", () => {
    render(<StatusBadge status="rejected" />);
    expect(screen.getByText("rejected")).toBeDefined();
  });

  it("should apply correct CSS classes for pending", () => {
    const { container } = render(<StatusBadge status="pending" />);
    const badge = container.querySelector("span");
    expect(badge?.className).toContain("bg-yellow-100");
  });

  it("should apply correct CSS classes for approved", () => {
    const { container } = render(<StatusBadge status="approved" />);
    const badge = container.querySelector("span");
    expect(badge?.className).toContain("bg-green-100");
  });

  it("should apply correct CSS classes for rejected", () => {
    const { container } = render(<StatusBadge status="rejected" />);
    const badge = container.querySelector("span");
    expect(badge?.className).toContain("bg-red-100");
  });
});
