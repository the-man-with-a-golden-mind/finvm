import bigInt from "big-integer";

function benchmarkStatistics(size) {
    const start = Date.now();
    let sum = bigInt(0);
    const data = [];
    for (let i = 0; i < size; i++) {
        data.push(bigInt(i));
    }
    for (let i = 0; i < size; i++) {
        sum = sum.add(data[i]);
    }
    const avg = sum.divide(size);
    const end = Date.now();
    return { time: end - start, sum: sum.toString(), avg: avg.toString() };
}

function benchmarkGraph(size) {
    const start = Date.now();
    const graph = new Map();
    for (let i = 0; i < size; i++) {
        graph.set(i, i + 1);
    }
    let current = 0;
    for (let i = 0; i < size; i++) {
        current = graph.get(current);
    }
    const end = Date.now();
    return { time: end - start, current };
}

const size = 10000;
const resultsStats = benchmarkStatistics(size);
console.log(`JS Benchmark (Statistics): ${size} items`);
console.log(`Time: ${resultsStats.time}ms`);

const resultsGraph = benchmarkGraph(size);
console.log(`JS Benchmark (Graph Traversal): ${size} nodes`);
console.log(`Time: ${resultsGraph.time}ms`);
