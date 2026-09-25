export interface StopNodeCommand {
  graphCommand: {
    projectPath: string;
    command: {
      stopNode: {
        _0: string;
      };
    };
  };
}

export function stopNodeCommand(
  projectPath: string,
  nodeId: string,
): StopNodeCommand {
  return {
    graphCommand: {
      projectPath,
      command: { stopNode: { _0: nodeId } },
    },
  };
}
