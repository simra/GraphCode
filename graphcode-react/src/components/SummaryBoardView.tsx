import type { SummaryBoard } from "../protocol/domain";

function BoardTableView({ board }: { board: SummaryBoard }) {
  const table = board.table;
  if (!table) return null;
  return (
    <div className="workspace-board-table-wrap">
      <table className="workspace-board-table">
        <thead>
          <tr>
            {table.headers.map((header, index) => (
              <th
                key={`${header}-${index}`}
                style={{
                  textAlign:
                    table.alignments[index] === "center"
                      ? "center"
                      : table.alignments[index] === "trailing"
                        ? "right"
                        : "left",
                }}
              >
                {header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {table.rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {table.headers.map((_, columnIndex) => (
                <td key={columnIndex}>{row[columnIndex] ?? ""}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function BoardFlowView({ board }: { board: SummaryBoard }) {
  const nodeNames = new Map(board.nodes.map((node) => [node.id, node.text]));
  return (
    <div
      className={`workspace-board-flow workspace-board-flow-${board.direction}`}
    >
      <ol aria-label="Flow steps">
        {board.nodes.map((node) => (
          <li key={node.id} className={`board-node board-node-${node.shape}`}>
            {node.text}
          </li>
        ))}
      </ol>
      <ul className="workspace-board-edges" aria-label="Flow connections">
        {board.edges.map((edge, index) => (
          <li key={`${edge.from}-${edge.to}-${edge.label ?? ""}-${index}`}>
            <span>{nodeNames.get(edge.from) ?? edge.from}</span>
            <span aria-hidden="true">→</span>
            <span>{nodeNames.get(edge.to) ?? edge.to}</span>
            {edge.label ? <small>{edge.label}</small> : null}
          </li>
        ))}
      </ul>
    </div>
  );
}

export function SummaryBoardView({ board }: { board: SummaryBoard }) {
  if (board.form === "table" && board.table) {
    return <BoardTableView board={board} />;
  }
  if (board.form === "flow" && board.nodes.length && board.edges.length) {
    return <BoardFlowView board={board} />;
  }
  return board.source ? (
    <pre className="workspace-board-source">{board.source}</pre>
  ) : (
    <p className="workspace-rail-empty">This board has no drawable content.</p>
  );
}
