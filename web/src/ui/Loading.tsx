/** The marching-dots pill that replaces the popup while generators are slow. */
export function Loading() {
  return (
    <div className="figo-loading" role="progressbar" aria-label="Loading suggestions">
      <div className="figo-loading-track">
        <div className="figo-loading-dot figo-loading-grow" />
        <div className="figo-loading-dot figo-loading-slide" />
        <div className="figo-loading-dot figo-loading-slide figo-loading-second" />
        <div className="figo-loading-dot figo-loading-shrink" />
      </div>
    </div>
  );
}
