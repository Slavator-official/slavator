"""Windows/Tk client of the same persistent meeting-memory worker as macOS."""
from __future__ import annotations

import json
import math
import os
import queue
import subprocess
import threading
import tkinter as tk
from pathlib import Path
from tkinter import ttk, messagebox

import app_config


class MemoryWindow(tk.Toplevel):
    def __init__(self, owner):
        super().__init__(owner)
        self.owner = owner
        self.build_graph = tk.BooleanVar(value=owner.settings.get("memory_graph_enabled", True))
        self.title("Спикеры и память встреч — Славатор")
        self.geometry("1100x800")
        self.minsize(900, 650)
        self.proc = None
        self.closed = False
        self.queue = queue.Queue()
        self.hits = []
        self.overview = {"people": [], "meetings": [], "edges": []}
        self.person_ids = [""]
        self.meeting_ids = [""]
        self.total = 0
        self.semantic_notice = ""
        self.mutating = False
        self.deleted = []
        self.show_unconfirmed = tk.BooleanVar(value=False)
        self.query = tk.StringVar()
        self.status = tk.StringVar(value="Читаю сохранённые встречи…")
        top = ttk.Frame(self,padding=16)
        top.pack(fill="x")
        ttk.Label(top,text="Спикеры и память встреч",font=(owner.font_name,19,"bold")).pack(side="left")
        ttk.Button(top,text="Обновить память",command=lambda:self.run({"action":"sync"})).pack(side="right")
        ttk.Button(top,text="Остановить",command=self.cancel).pack(side="right",padx=8)
        ttk.Label(self,textvariable=self.status,wraplength=1050,padding=12).pack(fill="x")
        tabs = ttk.Notebook(self)
        tabs.pack(fill="both",expand=True,padx=16,pady=8)
        search = ttk.Frame(tabs,padding=8)
        graph = ttk.Frame(tabs,padding=8)
        manage = ttk.Frame(tabs,padding=8)
        tabs.add(search,text="Поиск и история")
        tabs.add(graph,text="Граф встреч")
        tabs.add(manage,text="Встречи и корзина")
        self.tabs = tabs
        controls = ttk.Frame(search)
        controls.pack(fill="x")
        entry = ttk.Entry(controls,textvariable=self.query)
        entry.pack(side="left",fill="x",expand=True,padx=(0,8))
        entry.bind("<Return>",lambda _:self.search())
        ttk.Button(controls,text="Найти",command=self.search).pack(side="right")
        filters = ttk.Frame(search,padding=(0,10))
        filters.pack(fill="x")
        self.mode = ttk.Combobox(filters,values=["По смыслу","Точная фраза"],state="readonly",width=18)
        self.mode.current(0)
        self.mode.pack(side="left",padx=(0,8))
        self.people = ttk.Combobox(filters,values=["Все голоса"],state="readonly",width=34)
        self.people.current(0)
        self.people.pack(side="left",padx=(0,8))
        self.meetings = ttk.Combobox(filters,values=["Все встречи"],state="readonly",width=40)
        self.meetings.current(0)
        self.meetings.pack(side="left")
        for box in (self.mode,self.people,self.meetings):
            box.bind("<<ComboboxSelected>>",lambda _:self.search())
        self.controls = [(entry,"normal"),(self.mode,"readonly"),(self.people,"readonly"),(self.meetings,"readonly")]
        ttk.Label(search,text="Результат — исходная цитата, не ответ нейросети. Пустой запрос открывает хронологию.").pack(anchor="w",pady=(0,8))
        frame = ttk.Frame(search)
        frame.pack(fill="both",expand=True)
        self.tree = ttk.Treeview(frame,columns=("time","name","text","meeting"),show="headings",selectmode="browse",height=12)
        for key,title,width in (("time","Время",65),("name","Кто говорит",140),("text","Высказывание",460),("meeting","Встреча",240)):
            self.tree.heading(key,text=title)
            self.tree.column(key,width=width,minwidth=50)
        bar = ttk.Scrollbar(frame,command=self.tree.yview)
        self.tree.configure(yscrollcommand=bar.set)
        self.tree.pack(side="left",fill="both",expand=True)
        bar.pack(side="right",fill="y")
        self.tree.bind("<<TreeviewSelect>>",self.select)
        self.detail = tk.Text(search,height=10,wrap="word",font=(owner.font_name,12),state="disabled")
        self.detail.pack(fill="both",expand=True,pady=10)
        actions = ttk.Frame(search)
        actions.pack(fill="x")
        ttk.Button(actions,text="Папка встречи",command=self.open_folder).pack(side="left")
        ttk.Button(actions,text="Ещё 30",command=lambda:self.search(more=True)).pack(side="right")
        ttk.Label(graph,text="Линия означает совместную встречу. Нажмите на голос, чтобы открыть его реплики.\nНеопознанные голоса из разных встреч не объединяются.").pack(anchor="w")
        ttk.Checkbutton(graph,text="Строить граф встреч",variable=self.build_graph,command=self.toggle_graph).pack(anchor="w")
        ttk.Checkbutton(graph,text="Показать неопознанные голоса",variable=self.show_unconfirmed,command=self.draw_graph).pack(anchor="w")
        self.canvas = tk.Canvas(graph,bg="#111D2C",height=500,highlightthickness=0)
        self.canvas.pack(fill="both",expand=True,pady=10)
        self.canvas.bind("<Configure>",lambda _:self.draw_graph())
        ttk.Label(manage,text="Удаление перемещает все версии встречи в корзину Славатора. Исходное аудио и голосовые профили сохраняются.",wraplength=1000).pack(anchor="w",pady=8)
        self.meeting_tree = ttk.Treeview(manage,columns=("title","date"),show="headings",selectmode="browse",height=8)
        self.meeting_tree.heading("title",text="Сохранённая встреча")
        self.meeting_tree.heading("date",text="Обработано")
        self.meeting_tree.column("title",width=700)
        self.meeting_tree.pack(fill="both",expand=True)
        ttk.Button(manage,text="Удалить выбранную встречу…",command=self.delete_meeting).pack(anchor="e",pady=8)
        ttk.Label(manage,text="Корзина Славатора").pack(anchor="w")
        self.deleted_tree = ttk.Treeview(manage,columns=("title","count"),show="headings",selectmode="browse",height=5)
        self.deleted_tree.heading("title",text="Удалённая встреча")
        self.deleted_tree.heading("count",text="Версий")
        self.deleted_tree.column("title",width=700)
        self.deleted_tree.pack(fill="both",expand=True)
        ttk.Button(manage,text="Восстановить выбранную встречу",command=self.restore_meeting).pack(anchor="e",pady=8)
        self.protocol("WM_DELETE_WINDOW",self.close)
        self.after(100,self.poll)
        self.run({"action":"sync"})

    def run(self, request):
        if self.proc is not None or self.closed:
            return False
        request["build_graph"] = self.build_graph.get()
        script = Path(app_config.__file__).with_name("speaker_memory.py")
        try:
            process = subprocess.Popen([str(self.owner._find_python()),"-B",str(script),
                "--root",str(self.owner.settings["results_dir"]),"--profiles",str(self.owner.speakers.profiles_dir)],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                text=True,encoding="utf-8",env=app_config.environment(),
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            self.proc = process
            self.mutating = request["action"] in ("delete_meeting","restore_meeting")
            self.status.set("Читаю память встреч…")
            process.stdin.write(json.dumps(request,ensure_ascii=False)+"\n")
            process.stdin.close()
            for control,_ in self.controls:
                control.configure(state="disabled")
        except OSError as error:
            self.proc = None
            self.mutating = False
            self.status.set(str(error))
            return False
        def collect():
            try:
                for line in process.stdout:
                    try:
                        self.queue.put((process,request,json.loads(line)))
                    except ValueError:
                        continue
            finally:
                process.stdout.close()
                self.queue.put((process,request,{"event":"exit","code":process.wait()}))
        threading.Thread(target=collect,daemon=True).start()
        return True

    def poll(self):
        if self.closed:
            return
        while not self.queue.empty():
            process,request,data = self.queue.get_nowait()
            if process is not self.proc:
                continue
            event = data.get("event")
            if event in ("error","progress"):
                self.status.set(data.get("message","Ошибка чтения памяти"))
            elif event == "result":
                self.overview = data["overview"]
                self.deleted = data.get("deleted",self.deleted)
                self.update_meetings()
                self.update_filters()
                self.draw_graph()
                if request["action"] == "sync":
                    self.semantic_notice = data.get("notice","")
                self.status.set(data.get("notice") or self.semantic_notice or f'{len(self.overview["meetings"])} встреч · {len(self.overview["people"])} голосов · {self.overview["quotes"]} фрагментов')
                if data.get("warnings"):
                    self.status.set(self.status.get()+f' · Не прочитано файлов: {len(data["warnings"])}')
                if "hits" in data:
                    if not request.get("offset"):
                        self.hits = []
                        self.tree.delete(*self.tree.get_children())
                        self.show_text("")
                    self.hits.extend(data["hits"])
                    self.total = data["total"]
                    for hit in data["hits"]:
                        self.tree.insert("","end",iid=hit["id"],values=(self.time(hit),hit["name"],hit["text"],hit["title"]))
                    self.status.set(self.status.get()+f' · Найдено: {self.total}')
                if "context" in data and self.selected() and self.selected()["id"] == request["id"]:
                    self.show_text("\n\n".join(self.time(h)+" · "+h["name"]+"\n"+h["text"] for h in data["context"]))
            elif event == "exit":
                self.proc = None
                self.mutating = False
                for control,state in self.controls:
                    control.configure(state=state)
                if request["action"] in ("sync","delete_meeting","restore_meeting") and data["code"] == 0:
                    if request["action"] != "sync":
                        self.owner.render()
                    self.search()
        self.after(100,self.poll)

    @staticmethod
    def time(hit):
        n = int(hit["start"])
        return f"{n//60:02d}:{n%60:02d}"

    def update_filters(self):
        for box,key,ids,empty in ((self.people,"people",self.person_ids,"Все голоса"), (self.meetings,"meetings",self.meeting_ids,"Все встречи")):
            selected = ids[max(0,box.current())] if box.current() < len(ids) else ""
            rows = self.overview[key]
            ids[:] = [""]+[r["id"] for r in rows]
            box["values"] = [empty]+[r.get("name",r.get("title",""))+(" · не подтверждён" if r.get("identity")=="unconfirmed" else "") for r in rows]
            box.current(ids.index(selected) if selected in ids else 0)

    def search(self,more=False):
        if self.proc is not None:
            return
        self.run({"action":"search","query":self.query.get(),"mode":"semantic" if self.mode.current()==0 else "phrase",
            "person":self.person_ids[max(0,self.people.current())],"meeting":self.meeting_ids[max(0,self.meetings.current())],
            "offset":len(self.hits) if more else 0})

    def selected(self):
        selected = self.tree.selection()
        return next((h for h in self.hits if selected and h["id"]==selected[0]),None)

    def select(self,_=None):
        hit = self.selected()
        if hit:
            state = {"manual":"Голос назван вами","voice":"Совпадение профиля","unconfirmed":"Личность не подтверждена"}[hit["identity"]]
            self.show_text(state+" · "+hit["title"]+" · обработано "+hit["date"][:10]+"\n\n"+hit["text"])
            self.run({"action":"context","id":hit["id"]})

    def show_text(self,text):
        self.detail.configure(state="normal")
        self.detail.delete("1.0","end")
        self.detail.insert("end",text)
        self.detail.configure(state="disabled")

    def open_folder(self):
        hit = self.selected()
        if hit:
            if os.name == "nt":
                os.startfile(hit["meeting"])
            else:
                subprocess.Popen(["open" if __import__("sys").platform == "darwin" else "xdg-open",hit["meeting"]])

    def toggle_graph(self):
        self.owner.settings["memory_graph_enabled"] = self.build_graph.get()
        app_config.save(self.owner.settings)
        self.run({"action": "catalog"})
        self.draw_graph()

    def draw_graph(self):
        self.canvas.delete("all")
        if not self.build_graph.get():
            self.canvas.create_text(30, 30, anchor="nw", fill="#A7B4C7",
                text="Граф выключен. Поиск и история реплик продолжают работать.")
            return
        selected = self.person_ids[max(0,self.people.current())]
        edges = self.overview["edges"]
        adjacent = {p for e in edges if selected in (e["a"],e["b"]) for p in (e["a"],e["b"])} | {selected}
        people = [p for p in self.overview["people"]
                  if (not selected or p["id"] in adjacent)
                  and (self.show_unconfirmed.get() or p["id"].startswith("profile:") or p["id"] == selected)][:12]
        w,h = max(300,self.canvas.winfo_width()),max(300,self.canvas.winfo_height())
        points = {p["id"]:(w/2+math.cos(i/max(1,len(people))*math.tau-math.pi/2)*(w/2-95),h/2+math.sin(i/max(1,len(people))*math.tau-math.pi/2)*(h/2-60)) for i,p in enumerate(people)}
        for edge in edges:
            if edge["a"] in points and edge["b"] in points:
                line = self.canvas.create_line(*points[edge["a"]],*points[edge["b"]],fill="#6F97C8",width=min(6,1+len(edge["meetings"])))
                titles = [m["title"] for m in self.overview["meetings"] if m["id"] in edge["meetings"]]
                self.canvas.tag_bind(line,"<Button-1>",lambda _,t=titles:messagebox.showinfo("Общие встречи","\n".join(t),parent=self))
        for person in people:
            x,y = points[person["id"]]
            tag = person["id"]
            self.canvas.create_rectangle(x-80,y-27,x+80,y+27,fill="#1D3048",outline="#4A72A0",tags=tag)
            self.canvas.create_text(x,y,text=person["name"]+f'\n{person["meetings"]} встр. · {person["quotes"]} фр.',fill="#EDF2FA",width=150,tags=tag)
            self.canvas.tag_bind(tag,"<Button-1>",lambda _,pid=person["id"]:self.choose_person(pid))
        self.canvas.create_text(12,12,anchor="nw",fill="#BECDE0",text=f'Показано {len(people)} участников. По умолчанию — подтверждённые люди. Все голоса доступны в фильтре поиска.')

    def update_meetings(self):
        self.meeting_tree.delete(*self.meeting_tree.get_children())
        for meeting in self.overview["meetings"]:
            self.meeting_tree.insert("","end",iid=meeting["id"],values=(meeting["title"],meeting["date"][:10]))
        self.deleted_tree.delete(*self.deleted_tree.get_children())
        for entry in self.deleted:
            self.deleted_tree.insert("","end",iid=entry["id"],values=(entry["title"],entry["count"]))

    def delete_meeting(self):
        if self.proc is not None or self.owner.is_processing:
            return
        selected = self.meeting_tree.selection()
        meeting = next((m for m in self.overview["meetings"] if selected and m["id"] == selected[0]),None)
        if meeting and messagebox.askyesno("Удалить встречу?",f'«{meeting["title"]}» и все её прошлые версии будут перемещены в корзину Славатора. Исходное аудио и профили сохранятся. Встречу можно восстановить на этом экране.',parent=self):
            self.owner.stop_playback()
            self.run({"action":"delete_meeting","meeting":meeting["id"]})

    def restore_meeting(self):
        if self.proc is not None or self.owner.is_processing:
            return
        selected = self.deleted_tree.selection()
        if selected:
            self.run({"action":"restore_meeting","token":selected[0]})

    def choose_person(self,pid):
        if self.proc is None:
            self.people.current(self.person_ids.index(pid))
            self.meetings.current(0)
            self.query.set("")
            self.tabs.select(0)
            self.search()

    def cancel(self):
        if self.mutating:
            return
        if self.proc is not None:
            if self.proc.poll() is None:
                self.proc.terminate()
            self.proc = None
            for control,state in self.controls:
                control.configure(state=state)
            self.status.set("Остановлено. Уже сохранённая память не потеряна.")

    def close(self):
        self.closed = True
        self.cancel()
        self.destroy()
