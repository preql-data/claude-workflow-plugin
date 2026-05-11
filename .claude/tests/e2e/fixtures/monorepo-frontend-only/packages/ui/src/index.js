// @fixture/ui barrel export.
//
// The fixture's prompt asks Claude to add a RetryButton component to
// this package. After the change this barrel will re-export it so the
// app package can import from "@fixture/ui".
export { default as Button } from "./Button.jsx";
