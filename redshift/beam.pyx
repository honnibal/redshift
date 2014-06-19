# cython: profile=True
from _state cimport *
from redshift.sentence cimport Input, Sentence, Token

from transitions cimport Transition, transition

from libc.stdlib cimport malloc, calloc, free
from libc.string cimport memcpy
from libc.stdint cimport uint64_t, int64_t

from libcpp.queue cimport priority_queue
from libcpp.pair cimport pair
from cython.operator cimport dereference as deref, preincrement as inc

cimport cython


cdef class Beam:
    def __cinit__(self, float beta, size_t k, size_t moves_addr,
                  size_t nr_class, Input py_sent, init_words=True):
        self.length = py_sent.length
        self.nr_class = nr_class
        self.k = k
        self.beta = beta
        self.i = 0
        self.lattice = py_sent.c_sent.lattice
        self.sent = py_sent.c_sent
        self.is_finished = False
        cdef size_t i
        self.parents = <State**>malloc(k * sizeof(State*))
        self.beam = <State**>malloc(k * sizeof(State*))
        self.moves = <Transition**>malloc(k * sizeof(Transition*))
        cdef Transition* moves = <Transition*>moves_addr
        for i in range(k):
            self.parents[i] = init_state(py_sent.length)
            self.beam[i] = init_state(py_sent.length)
            if init_words:
                for w in range(self.beam[i].n):
                    self.beam[i].parse[w].word = self.sent.tokens[w].word
                    self.beam[i].parse[w].tag = self.sent.tokens[w].tag
            self.moves[i] = <Transition*>calloc(self.nr_class, sizeof(Transition))
            for j in range(self.nr_class):
                assert moves[j].clas < nr_class
                self.moves[i][j].clas = moves[j].clas
                self.moves[i][j].move = moves[j].move
                self.moves[i][j].label = moves[j].label
                self.moves[i][j].is_valid = True
                self.moves[i][j].score = 0
                self.moves[i][j].cost = py_sent.wer
        self.bsize = 1
        self.psize = 0
        self.t = 0
        self.is_full = self.bsize >= self.k

    property score:
        def __get__(self):
            return self.beam[0].score

    property cost:
        def __get__(self):
            return self.beam[0].cost

    @cython.cdivision(True)
    cdef int extend(self):
        cdef priority_queue[ScoredMove] queue = priority_queue[ScoredMove]()
        cdef size_t i, j, move_id
        cdef double score
        for i in range(self.bsize):
            if is_final(self.beam[i]):
                score = self.beam[i].score + (self.beam[i].score / self.t)
                queue.push(ScoredMove(score, i * self.nr_class))
                continue
            for j in range(self.nr_class):
                if self.moves[i][j].is_valid:
                    move_id = (i * self.nr_class) + j
                    score = self.moves[i][j].score
                    queue.push(ScoredMove(score, move_id))
        # Former states are now parents, beam will hold the extensions
        cdef State** parents = self.parents
        self.parents = self.beam
        self.beam = parents 
        self.psize = self.bsize
        self.bsize = 0
        cdef State* parent
        cdef State* s
        cdef Transition* t
        cdef ScoredMove data
        cdef size_t move_idx
        cdef size_t parent_idx
        cdef double cutoff
        if queue.empty():
            cutoff = 0
        elif queue.top().first >= 0:
            cutoff = queue.top().first * self.beta
        else:
            cutoff = queue.top().first / self.beta
        while not queue.empty() and self.bsize < self.k:
            data = queue.top()
            if self.beta and data.first < cutoff:
                break
            parent_idx = data.second / self.nr_class
            move_idx = data.second % self.nr_class
            # We've got two arrays of states, and we swap beam-for-parents.
            # So, s here will get manipulated, then its beam will replace
            # parents later.
            copy_state(self.beam[self.bsize], self.parents[parent_idx])
            s = self.beam[self.bsize]
            s.score = data.first
            if not is_final(s):
                t = &self.moves[parent_idx][move_idx]
                assert t.cost >= 0
                s.cost += t.cost
                transition(t, s, self.lattice)
                assert s.m != 0
            self.bsize += 1
            queue.pop()
        hist = <Transition*>malloc(self.beam[0].m * sizeof(Transition))
        memcpy(hist, self.beam[0].history, self.beam[0].m * sizeof(Transition))
        self.history.push_back(hist)
        self.scores.push_back(self.beam[0].score)
        self.costs.push_back(self.beam[0].cost)
        self.lengths.push_back(self.beam[0].m)
        self.t += 1
        self.is_full = self.bsize >= self.k
        assert self.beam[0].m != 0
        for i in range(self.bsize):
            if not is_final(self.beam[i]):
                self.is_finished = False
                break
        else:
            self.is_finished = True

    cdef int fill_parse(self, Token* parse) except -1:
        cdef size_t i, head 
        cdef State* s = self.beam[0]
        for i in range(1, s.n-1):
            head = i
            while s.parse[head].head != head and \
                  s.parse[head].head < (s.n-1) and \
                  s.parse[head].head != 0:
                head = s.parse[head].head
            s.parse[i].sent_id = head
        # No need to copy heads for root and start symbols
        for i in range(1, self.length - 1):
            parse[i] = s.parse[i]
 
    def __dealloc__(self):
        for i in range(self.k):
            free(self.moves[i])
            free_state(self.beam[i])
            free_state(self.parents[i])
        for i in range(self.t):
            free(self.history[i])
        free(self.beam)
        free(self.parents)
        free(self.moves)

    # Violation helpers
    # TODO: Is ternary assignment out of the vector a Cython bug??
    cdef History hist_at(self, size_t i):
        cdef History hist
        if i < self.t:
            hist = self.history[i]
        else:
            hist = self.history[self.t - 1]
        return hist

    cdef size_t length_at(self, size_t i):
        cdef size_t length
        if i < self.t:
            length = self.lengths[i]
        else:
            length = self.lengths[self.t - 1]
        return length

    cdef double score_at(self, size_t i):
        cdef double score
        if i < self.t:
            score = self.scores[i]
        else:
            score = self.scores[self.t - 1]
        return score

    cdef int cost_at(self, size_t i):
        cdef int cost
        if i < self.t:
            cost = self.costs[i]
        else:
            cost = self.costs[self.t - 1]
        return cost


cdef int get_violation(Beam pred, Beam gold):
    cdef double max_violn = -1
    cdef int v = -1
    for i in range(max(pred.t, gold.t)):
        if pred.cost_at(i) < 1:
            continue
        pred_score = pred.score_at(i)
        gold_score = gold.score_at(i)
        if pred_score - gold_score > max_violn:
            max_violn = pred_score - gold_score
            v = i 
    return v
